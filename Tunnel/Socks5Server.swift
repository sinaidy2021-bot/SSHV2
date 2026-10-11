import Foundation
import Network

final class Stats {
    private let lock = NSLock()
    private var active = 0, total = 0
    private var up: UInt64 = 0, down: UInt64 = 0

    func opened() { lock.lock(); active += 1; total += 1; lock.unlock() }
    func closed() { lock.lock(); active = max(0, active - 1); lock.unlock() }
    func addUp(_ n: Int) { lock.lock(); up += UInt64(n); lock.unlock() }
    func addDown(_ n: Int) { lock.lock(); down += UInt64(n); lock.unlock() }
    func snapshot() -> (active: Int, total: Int, up: UInt64, down: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (active, total, up, down)
    }
}

enum Socks5Error: Error { case listenTimeout, noPort }

/// 仅监听手机本机 127.0.0.1 的 SOCKS5 服务（支持用户名/密码认证，仅 TCP CONNECT）。
final class Socks5Server {
    let user: String
    let pass: String
    let cellularOnly: Bool
    let stats: Stats
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "socks5.listener", qos: .userInitiated)

    var requiresAuth: Bool { !user.isEmpty }

    init(user: String, pass: String, cellularOnly: Bool, stats: Stats) {
        self.user = user
        self.pass = pass
        self.cellularOnly = cellularOnly
        self.stats = stats
    }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)

        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: sem.signal()
            case .failed(let e): failure = e; sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self = self else { conn.cancel(); return }
            Socks5Session(conn, server: self).start()
        }
        l.start(queue: queue)
        if sem.wait(timeout: .now() + 5) == .timedOut {
            l.cancel()
            throw Socks5Error.listenTimeout
        }
        if let failure = failure { throw failure }
        guard let port = l.port?.rawValue else { throw Socks5Error.noPort }
        listener = l
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var r: UInt8 = (a.count == b.count) ? 0 : 1
    for i in 0..<min(a.count, b.count) { r |= a[i] ^ b[i] }
    return r == 0
}

final class Socks5Session {
    private let c: NWConnection
    private let server: Socks5Server
    private let q = DispatchQueue(label: "socks5.session", qos: .userInitiated)
    private var out: NWConnection?
    private var keep: Socks5Session?
    private var done = false
    private var piping = false
    private var counted = false
    private var replied = false
    private var halfClosed = 0

    init(_ c: NWConnection, server: Socks5Server) {
        self.c = c
        self.server = server
    }

    func start() {
        q.async { self.begin() }
    }

    private func begin() {
        keep = self
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let s = self, !s.done, !s.piping else { return }
            s.close()
        }
        readExact(2) { [weak self] h in self?.greeting(h) }
    }

    func close() {
        if done { return }
        done = true
        c.cancel()
        out?.cancel()
        if counted { server.stats.closed() }
        keep = nil
    }

    // MARK: - 基础读写

    private func readExact(_ n: Int, _ cb: @escaping ([UInt8]) -> Void) {
        if n == 0 { cb([]); return }
        c.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, err in
            guard let self = self, !self.done else { return }
            guard err == nil, let data = data, data.count == n else { self.close(); return }
            cb([UInt8](data))
        }
    }

    private func write(_ bytes: [UInt8], then: (() -> Void)? = nil) {
        c.send(content: Data(bytes), completion: .contentProcessed { [weak self] err in
            guard let self = self, !self.done else { return }
            if err != nil { self.close(); return }
            then?()
        })
    }

    // MARK: - 握手

    private func greeting(_ h: [UInt8]) {
        guard h[0] == 5 else { close(); return }
        readExact(Int(h[1])) { [weak self] methods in
            guard let self = self else { return }
            let want: UInt8 = self.server.requiresAuth ? 0x02 : 0x00
            if methods.contains(want) {
                self.write([5, want]) {
                    if self.server.requiresAuth { self.authStep() } else { self.requestStep() }
                }
            } else {
                self.write([5, 0xFF]) { self.close() }
            }
        }
    }

    private func authStep() {
        readExact(2) { [weak self] h in
            guard let self = self, h[0] == 1 else { self?.close(); return }
            self.readExact(Int(h[1]) + 1) { rest in
                let u = Array(rest.dropLast())
                let plen = Int(rest.last ?? 0)
                self.readExact(plen) { p in
                    let ok = constantTimeEqual(u, Array(self.server.user.utf8)) &&
                             constantTimeEqual(p, Array(self.server.pass.utf8))
                    if ok {
                        self.write([1, 0]) { self.requestStep() }
                    } else {
                        // 失败后延迟 1 秒再回应，拖慢暴力尝试
                        self.q.asyncAfter(deadline: .now() + 1) {
                            self.write([1, 1]) { self.close() }
                        }
                    }
                }
            }
        }
    }

    private func requestStep() {
        readExact(4) { [weak self] h in
            guard let self = self, h[0] == 5 else { self?.close(); return }
            guard h[1] == 1 else { self.reply(0x07); return }   // 仅支持 CONNECT
            switch h[3] {
            case 1:
                self.readExact(4 + 2) { b in
                    if b[0] == 127 { self.reply(0x02); return }
                    guard let ip = IPv4Address(Data(b[0..<4])) else { self.reply(0x08); return }
                    self.dial(.ipv4(ip), port: b[4], b[5])
                }
            case 3:
                self.readExact(1) { l in
                    self.readExact(Int(l[0]) + 2) { b in
                        let name = String(decoding: b.dropLast(2), as: UTF8.self)
                        if name.lowercased() == "localhost" { self.reply(0x02); return }
                        self.dial(.name(name, nil), port: b[b.count - 2], b[b.count - 1])
                    }
                }
            case 4:
                self.readExact(16 + 2) { b in
                    guard let ip = IPv6Address(Data(b[0..<16])) else { self.reply(0x08); return }
                    self.dial(.ipv6(ip), port: b[16], b[17])
                }
            default:
                self.reply(0x08)
            }
        }
    }

    private func reply(_ code: UInt8, then: (() -> Void)? = nil) {
        if replied { return }
        replied = true
        write([5, code, 0, 1, 0, 0, 0, 0, 0, 0]) {
            if code != 0 { self.close() } else { then?() }
        }
    }

    // MARK: - 出站连接

    private func dial(_ host: NWEndpoint.Host, port hi: UInt8, _ lo: UInt8) {
        let portNum = (UInt16(hi) << 8) | UInt16(lo)
        guard let port = NWEndpoint.Port(rawValue: portNum), portNum != 0 else { reply(0x01); return }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let params = NWParameters(tls: nil, tcp: tcp)
        if server.cellularOnly { params.requiredInterfaceType = .cellular }

        let o = NWConnection(host: host, port: port, using: params)
        out = o
        o.stateUpdateHandler = { [weak self] st in
            guard let self = self, !self.done else { return }
            switch st {
            case .ready:
                if !self.replied { self.reply(0x00) { self.pipe() } }
            case .failed(let e):
                if !self.replied { self.reply(Socks5Session.code(for: e)) } else { self.close() }
            default: break
            }
        }
        o.start(queue: q)
        // 蜂窝不可用时连接会停在 waiting，这里统一超时
        q.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, !self.done, !self.replied else { return }
            self.reply(0x04)
        }
    }

    private static func code(for e: NWError) -> UInt8 {
        if case .posix(let p) = e {
            switch p {
            case .ECONNREFUSED: return 0x05
            case .ENETUNREACH: return 0x03
            case .EHOSTUNREACH: return 0x04
            case .ETIMEDOUT: return 0x04
            default: return 0x01
            }
        }
        return 0x04   // DNS 等其他错误
    }

    // MARK: - 双向转发

    private func pipe() {
        guard let o = out else { close(); return }
        piping = true
        counted = true
        server.stats.opened()
        forward(from: c, to: o, up: true)
        forward(from: o, to: c, up: false)
    }

    private func forward(from a: NWConnection, to b: NWConnection, up: Bool) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self = self, !self.done else { return }
            if err != nil { self.close(); return }
            if let data = data, !data.isEmpty {
                if up { self.server.stats.addUp(data.count) } else { self.server.stats.addDown(data.count) }
                b.send(content: data, completion: .contentProcessed { [weak self] e in
                    guard let self = self, !self.done else { return }
                    if e != nil { self.close(); return }
                    if isComplete { self.halfClose(b) } else { self.forward(from: a, to: b, up: up) }
                })
            } else if isComplete {
                self.halfClose(b)
            } else {
                self.forward(from: a, to: b, up: up)
            }
        }
    }

    private func halfClose(_ b: NWConnection) {
        b.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in })
        halfClosed += 1
        if halfClosed >= 2 { close() }
    }
}
