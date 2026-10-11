import Foundation
import Network

/// 协调 SOCKS5 服务、SSH 反向隧道、网络路径监控与状态。
final class ProxyCore {
    private let cfg: ProxyConfig
    private let lock = NSLock()
    private var st = TunnelStatus()
    private let stats = Stats()

    private var socks: Socks5Server?
    private var tunnel: SSHReverseTunnel?

    private let mon = NWPathMonitor()
    private let cellMon = NWPathMonitor(requiredInterfaceType: .cellular)
    private let q = DispatchQueue(label: "proxycore.path")

    private var fullSig = ""
    private var cellSig = ""
    private var cellIdx: UInt32 = 0
    private var pathSatisfied = true
    private var cellSatisfied = false
    private var onlineCount = 0

    init(config: ProxyConfig) {
        self.cfg = config
    }

    func start() {
        set(.connecting, "启动本地 SOCKS5…")
        do {
            let s = Socks5Server(user: cfg.socksUser, pass: cfg.socksPass,
                                 cellularOnly: cfg.forceCellularExit, stats: stats)
            let port = try s.start()
            socks = s

            let hooks = SSHReverseTunnel.Hooks(
                state: { [weak self] state, msg in self?.set(state, msg) },
                hostKey: { [weak self] fp in self?.setFingerprint(fp) },
                cellularIndex: { [weak self] in self?.currentCellIndex() ?? 0 },
                networkOK: { [weak self] in self?.networkUsable() ?? true }
            )
            let t = SSHReverseTunnel(cfg: cfg, socksPort: port, hooks: hooks)
            tunnel = t

            mon.pathUpdateHandler = { [weak self] p in self?.pathChanged(p) }
            cellMon.pathUpdateHandler = { [weak self] p in self?.cellChanged(p) }
            mon.start(queue: q)
            cellMon.start(queue: q)
            t.start()
        } catch {
            set(.error, "本地 SOCKS5 启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        mon.cancel()
        cellMon.cancel()
        tunnel?.stop()
        socks?.stop()
        tunnel = nil
        socks = nil
        set(.idle, "已停止")
    }

    func snapshot() -> TunnelStatus {
        lock.lock(); defer { lock.unlock() }
        var s = st
        let x = stats.snapshot()
        s.activeConnections = x.active
        s.totalConnections = x.total
        s.bytesUp = x.up
        s.bytesDown = x.down
        return s
    }

    // MARK: - 状态

    private func set(_ state: LinkState, _ msg: String) {
        lock.lock()
        if state == .online && st.state != .online {
            onlineCount += 1
            if onlineCount > 1 { st.reconnects += 1 }
        }
        st.state = state
        st.message = msg
        st.lastChange = Date()
        lock.unlock()
    }

    private func setFingerprint(_ fp: String) {
        lock.lock(); st.hostKeyFingerprint = fp; lock.unlock()
    }

    private func currentCellIndex() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return cellIdx
    }

    private func networkUsable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cfg.forceCellularSSH ? cellSatisfied : pathSatisfied
    }

    // MARK: - 网络切换

    private func pathChanged(_ p: NWPath) {
        let type: String
        if p.status != .satisfied { type = "none" }
        else if p.usesInterfaceType(.wifi) { type = "wifi" }
        else if p.usesInterfaceType(.cellular) { type = "cellular" }
        else if p.usesInterfaceType(.wiredEthernet) { type = "wired" }
        else { type = "other" }

        let names = p.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
        let sig = "\(p.status)|\(type)|\(names)"

        lock.lock()
        st.networkType = type
        pathSatisfied = (p.status == .satisfied)
        let changed = !fullSig.isEmpty && sig != fullSig
        fullSig = sig
        lock.unlock()

        if changed && !cfg.forceCellularSSH {
            set(.reconnecting, "网络切换（\(type)），正在重连…")
            tunnel?.kick(interrupt: true)
        }
    }

    private func cellChanged(_ p: NWPath) {
        let idx = p.availableInterfaces.first?.index ?? 0
        let sig = "\(p.status)|\(idx)"

        lock.lock()
        st.cellularAvailable = (p.status == .satisfied)
        cellSatisfied = (p.status == .satisfied)
        cellIdx = UInt32(idx)
        let changed = !cellSig.isEmpty && sig != cellSig
        cellSig = sig
        lock.unlock()

        if changed && cfg.forceCellularSSH {
            set(.reconnecting, "蜂窝网络变化，正在重连…")
            tunnel?.kick(interrupt: true)
        } else if changed {
            // 出口走蜂窝：蜂窝恢复后让等待中的隧道立即重试
            tunnel?.kick(interrupt: false)
        }
    }
}
