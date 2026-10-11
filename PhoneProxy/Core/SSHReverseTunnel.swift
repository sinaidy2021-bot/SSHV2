import Foundation
import Darwin
import CSSH

/// 等价于 `ssh -N -R 127.0.0.1:<remotePort>:127.0.0.1:<localSocksPort> user@vps`：
/// 手机主动连 VPS，向 sshd 发送 tcpip-forward 请求，VPS 上每个进入 127.0.0.1:<remotePort>
/// 的连接都会变成一个 forwarded-tcpip 通道，这里把它桥接到手机本机的 SOCKS5 服务。
/// 基于 libssh2，单线程 poll 事件循环，自动重连。

private let EAGAIN_SSH = -37   // LIBSSH2_ERROR_EAGAIN

enum SSHError: Error {
    case msg(String)     // 可重试
    case fatal(String)   // 认证 / 指纹问题，退避到最大间隔
}

private final class Pair {
    let ch: OpaquePointer
    let fd: Int32
    var toLocal = [UInt8]()   // 通道 -> 本地 SOCKS
    var toChan = [UInt8]()    // 本地 SOCKS -> 通道
    var chEOF = false
    var localEOF = false
    var sentEOF = false
    var shutWR = false
    var last = Date()
    init(ch: OpaquePointer, fd: Int32) { self.ch = ch; self.fd = fd }
}

final class SSHReverseTunnel {
    struct Hooks {
        var state: (LinkState, String) -> Void
        var hostKey: (String) -> Void
        var cellularIndex: () -> UInt32
        var networkOK: () -> Bool
    }

    private let cfg: ProxyConfig
    private let socksPort: UInt16
    private let hooks: Hooks

    private let lk = NSLock()
    private var stopped = false
    private var curFD: Int32 = -1
    private var immediate = false
    private var gen = 0
    private let wake = DispatchSemaphore(value: 0)

    init(cfg: ProxyConfig, socksPort: UInt16, hooks: Hooks) {
        self.cfg = cfg
        self.socksPort = socksPort
        self.hooks = hooks
    }

    // MARK: - 控制

    func start() {
        let t = Thread { [weak self] in self?.runForever() }
        t.name = "ssh-reverse-tunnel"
        t.stackSize = 1 << 20
        t.start()
    }

    func stop() {
        lk.lock()
        stopped = true
        if curFD >= 0 { shutdown(curFD, SHUT_RDWR) }
        lk.unlock()
        wake.signal()
    }

    /// 网络变化时调用。interrupt=true 会打断当前（可能已失效的）连接。
    func kick(interrupt: Bool) {
        lk.lock()
        immediate = true
        if interrupt {
            gen += 1
            if curFD >= 0 { shutdown(curFD, SHUT_RDWR) }
        }
        lk.unlock()
        wake.signal()
    }

    private var isStopped: Bool { lk.lock(); defer { lk.unlock() }; return stopped }
    private var generation: Int { lk.lock(); defer { lk.unlock() }; return gen }
    private func takeImmediate() -> Bool {
        lk.lock(); defer { lk.unlock() }
        let v = immediate; immediate = false; return v
    }

    // MARK: - 重连循环

    private func runForever() {
        libssh2_init(0)
        defer { libssh2_exit() }
        var backoff = 1.0

        while !isStopped {
            if !hooks.networkOK() {
                hooks.state(.reconnecting, "等待网络…")
                _ = wake.wait(timeout: .now() + 5)
                _ = takeImmediate()
                continue
            }
            hooks.state(.connecting, "正在连接 \(cfg.sshHost):\(cfg.sshPort)…")
            let started = Date()
            var delay = backoff
            do {
                try runSession()
            } catch SSHError.fatal(let m) {
                hooks.state(.error, m)
                delay = 30
            } catch SSHError.msg(let m) {
                hooks.state(.reconnecting, m)
            } catch {
                hooks.state(.reconnecting, error.localizedDescription)
            }
            if isStopped { break }

            if Date().timeIntervalSince(started) > 30 { backoff = 1; delay = 1 }
            if takeImmediate() {
                backoff = 1
                delay = 0.3
            } else {
                backoff = min(backoff * 2, 30)
            }
            _ = wake.wait(timeout: .now() + delay)
        }
    }

    // MARK: - 一次会话

    private func runSession() throws {
        let startGen = generation
        let fd = try openSocket()
        lk.lock(); curFD = fd; lk.unlock()

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            lk.lock(); curFD = -1; lk.unlock()
            close(fd)
            throw SSHError.msg("libssh2 初始化失败")
        }

        var pairs: [Pair] = []
        var closing: [OpaquePointer] = []
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 32768)

        defer {
            lk.lock(); curFD = -1; lk.unlock()
            for p in pairs { close(p.fd) }
            buf.deallocate()
            libssh2_session_set_blocking(session, 1)
            libssh2_session_set_timeout(session, 2000)
            libssh2_session_free(session)
            close(fd)
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 15000)

        if libssh2_session_handshake(session, fd) != 0 {
            throw lastError(session, "SSH 握手失败")
        }

        // 主机指纹
        guard let h = libssh2_hostkey_hash(session, 3) else {   // 3 = SHA256
            throw SSHError.fatal("无法获取主机指纹")
        }
        let fp = "SHA256:" + Data(bytes: h, count: 32).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        hooks.hostKey(fp)
        if !cfg.hostKeyFingerprint.isEmpty && cfg.hostKeyFingerprint != fp {
            throw SSHError.fatal("主机指纹不匹配，已拒绝连接：\(fp)")
        }

        // 认证
        let user = cfg.sshUser
        var rc: Int32 = -1
        let key = cfg.privateKey.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if key.count > 2 {
            rc = libssh2_userauth_publickey_frommemory(
                session, user, user.utf8.count, nil, 0, key, key.utf8.count,
                cfg.keyPassphrase.isEmpty ? nil : cfg.keyPassphrase)
        } else if !cfg.sshPassword.isEmpty {
            rc = libssh2_userauth_password_ex(
                session, user, UInt32(user.utf8.count),
                cfg.sshPassword, UInt32(cfg.sshPassword.utf8.count), nil)
        } else {
            throw SSHError.fatal("未配置私钥或密码")
        }
        if rc != 0 {
            if case .msg(let m) = lastError(session, "认证失败") { throw SSHError.fatal(m) }
            throw SSHError.fatal("认证失败")
        }

        // 等价于 ssh -R 127.0.0.1:<remote>:...
        var bound: Int32 = 0
        guard let listener = libssh2_channel_forward_listen_ex(
            session, "127.0.0.1", Int32(cfg.remoteBindPort), &bound, 16) else {
            if case .msg(let m) = lastError(session, "VPS 拒绝监听 127.0.0.1:\(cfg.remoteBindPort)") {
                throw SSHError.msg(m + "（端口被旧连接占用或 permitlisten 不匹配）")
            }
            throw SSHError.msg("VPS 拒绝监听")
        }

        libssh2_session_set_blocking(session, 0)
        libssh2_keepalive_config(session, 1, UInt32(max(5, cfg.keepaliveSeconds)))
        hooks.state(.online, "已连接 · VPS 127.0.0.1:\(cfg.remoteBindPort)")

        var lastRx = Date()
        let rxLimit = Double(max(5, cfg.keepaliveSeconds) * 3 + 5)

        while true {
            if isStopped { throw SSHError.msg("已停止") }
            if generation != startGen { throw SSHError.msg("网络变化，正在重连…") }

            // 接收 VPS 上新进来的连接
            while pairs.count < 128 {
                if let ch = libssh2_channel_forward_accept(listener) {
                    if let lfd = connectLocal() {
                        pairs.append(Pair(ch: ch, fd: lfd))
                    } else {
                        closing.append(ch)
                    }
                } else {
                    let e = libssh2_session_last_errno(session)
                    if Int(e) == EAGAIN_SSH { break }
                    throw lastError(session, "连接中断")
                }
            }

            // 搬运数据
            var i = 0
            while i < pairs.count {
                if service(pairs[i], buf) {
                    i += 1
                } else {
                    close(pairs[i].fd)
                    closing.append(pairs[i].ch)
                    pairs.remove(at: i)
                }
            }

            // 收尾已结束的通道
            closing.removeAll { ch in
                if Int(libssh2_channel_close(ch)) == EAGAIN_SSH { return false }
                if Int(libssh2_channel_free(ch)) == EAGAIN_SSH { return false }
                return true
            }

            // 心跳
            var next: Int32 = 0
            let kr = libssh2_keepalive_send(session, &next)
            if kr != 0 && Int(kr) != EAGAIN_SSH { throw lastError(session, "心跳发送失败") }

            // 等待事件
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            for p in pairs {
                var ev: Int16 = 0
                if p.toChan.isEmpty && !p.localEOF { ev |= Int16(POLLIN) }
                if !p.toLocal.isEmpty { ev |= Int16(POLLOUT) }
                fds.append(pollfd(fd: p.fd, events: ev, revents: 0))
            }
            let pr = poll(&fds, nfds_t(fds.count), pairs.isEmpty ? 500 : 200)
            if pr < 0 && errno != EINTR { throw SSHError.msg("poll 失败") }

            let rev = Int32(fds[0].revents)
            if rev & POLLIN != 0 { lastRx = Date() }
            if rev & (POLLERR | POLLNVAL) != 0 || (rev & POLLHUP != 0 && rev & POLLIN == 0) {
                throw SSHError.msg("连接已断开")
            }
            if Date().timeIntervalSince(lastRx) > rxLimit {
                throw SSHError.msg("心跳超时，正在重连…")
            }
        }
    }

    // MARK: - 数据搬运

    private func flushLocal(_ p: Pair) -> Bool {
        while !p.toLocal.isEmpty {
            let n = p.toLocal.withUnsafeBytes { send(p.fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                p.toLocal.removeFirst(n)
                p.last = Date()
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return true
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// 返回 false 表示这一对已结束，应当关闭。
    private func service(_ p: Pair, _ buf: UnsafeMutablePointer<CChar>) -> Bool {
        if !flushLocal(p) { return false }

        // 通道 -> 本地
        var rounds = 0
        while p.toLocal.isEmpty && !p.chEOF && rounds < 8 {
            rounds += 1
            let n = libssh2_channel_read_ex(p.ch, 0, buf, 32768)
            if n > 0 {
                p.toLocal.append(contentsOf: UnsafeRawBufferPointer(start: buf, count: n))
                p.last = Date()
                if !flushLocal(p) { return false }
            } else if n == EAGAIN_SSH {
                break
            } else if n < 0 {
                return false
            } else {
                break
            }
        }
        if libssh2_channel_eof(p.ch) == 1 && p.toLocal.isEmpty { p.chEOF = true }
        if p.chEOF && p.toLocal.isEmpty && !p.shutWR {
            shutdown(p.fd, SHUT_WR)
            p.shutWR = true
        }

        // 本地 -> 通道
        if p.toChan.isEmpty && !p.localEOF {
            let n = recv(p.fd, UnsafeMutableRawPointer(buf), 32768, 0)
            if n > 0 {
                p.toChan.append(contentsOf: UnsafeRawBufferPointer(start: buf, count: n))
                p.last = Date()
            } else if n == 0 {
                p.localEOF = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                return false
            }
        }
        while !p.toChan.isEmpty {
            let w = p.toChan.withUnsafeBytes {
                libssh2_channel_write_ex(p.ch, 0,
                                         $0.baseAddress!.assumingMemoryBound(to: CChar.self),
                                         $0.count)
            }
            if w > 0 {
                p.toChan.removeFirst(w)
                p.last = Date()
            } else if w == EAGAIN_SSH {
                break
            } else {
                return false
            }
        }
        if p.localEOF && p.toChan.isEmpty && !p.sentEOF {
            if Int(libssh2_channel_send_eof(p.ch)) != EAGAIN_SSH { p.sentEOF = true }
        }

        if p.chEOF && p.localEOF && p.toLocal.isEmpty && p.toChan.isEmpty { return false }
        if Date().timeIntervalSince(p.last) > 900 { return false }
        return true
    }

    // MARK: - Socket 辅助

    private func connectLocal() -> Int32? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = socksPort.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { close(s); return nil }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return s
    }

    private func openSocket() throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let g = getaddrinfo(cfg.sshHost, String(cfg.sshPort), &hints, &res)
        guard g == 0, let first = res else {
            throw SSHError.msg("DNS 解析失败：\(cfg.sshHost)")
        }
        defer { freeaddrinfo(res) }

        var boundIf: Int32 = 0
        if cfg.forceCellularSSH {
            boundIf = Int32(hooks.cellularIndex())
            if boundIf == 0 { throw SSHError.msg("蜂窝网络不可用，等待中…") }
        }

        var lastErr = "无法连接"
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s < 0 { continue }

            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            if boundIf != 0 {
                var idx = boundIf
                if ai.pointee.ai_family == AF_INET6 {
                    setsockopt(s, IPPROTO_IPV6, IPV6_BOUND_IF, &idx, 4)
                } else {
                    setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, 4)
                }
            }

            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
            let r = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if r != 0 {
                if errno != EINPROGRESS {
                    lastErr = String(cString: strerror(errno))
                    close(s); continue
                }
                var pf = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pf, 1, 10000)
                var soerr: Int32 = 0
                var len = socklen_t(4)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &len)
                if pr <= 0 || soerr != 0 {
                    lastErr = pr == 0 ? "连接超时" : String(cString: strerror(soerr))
                    close(s); continue
                }
            }

            // 握手/认证阶段使用阻塞模式
            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) & ~O_NONBLOCK)
            var idle: Int32 = 15, intvl: Int32 = 5, cnt: Int32 = 3
            setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, 4)
            setsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, &idle, 4)
            setsockopt(s, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, 4)
            setsockopt(s, IPPROTO_TCP, TCP_KEEPCNT, &cnt, 4)
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, 4)
            return s
        }
        throw SSHError.msg("连接 \(cfg.sshHost) 失败：\(lastErr)")
    }

    private func lastError(_ s: OpaquePointer, _ prefix: String) -> SSHError {
        var msg: UnsafeMutablePointer<CChar>? = nil
        var len: Int32 = 0
        let code = libssh2_session_last_error(s, &msg, &len, 0)
        let text = msg.map { String(cString: $0) } ?? "未知错误"
        return .msg("\(prefix)：\(text) (\(code))")
    }
}
