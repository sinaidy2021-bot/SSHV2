import Foundation

@MainActor
final class ProxyService: ObservableObject {
    @Published var config = ProxyConfig()
    @Published var status = TunnelStatus()
    @Published var running = false
    @Published var lastError = ""
    @Published var autoResume: Bool {
        didSet { UserDefaults.standard.set(autoResume, forKey: "autoResume") }
    }

    private var core: ProxyCore?
    private let keepAlive = KeepAlive()
    private var timer: Timer?

    init() {
        autoResume = UserDefaults.standard.object(forKey: "autoResume") as? Bool ?? true
        if let d = Keychain.load(),
           let c = try? Codec.decoder.decode(ProxyConfig.self, from: d) {
            config = c
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // 上次是运行状态，启动 App 时自动恢复
        if autoResume, UserDefaults.standard.bool(forKey: "wasRunning") { start() }
    }

    func saveConfig() {
        if let d = try? Codec.encoder.encode(config) { Keychain.save(d) }
    }

    func pinHostKey() {
        guard !status.hostKeyFingerprint.isEmpty else { return }
        config.hostKeyFingerprint = status.hostKeyFingerprint
        saveConfig()
        if running { lastError = "指纹已保存，重新启动后生效" }
    }

    private func validate() -> Bool {
        if config.sshHost.trimmingCharacters(in: .whitespaces).isEmpty ||
            config.sshUser.trimmingCharacters(in: .whitespaces).isEmpty {
            lastError = "请填写 VPS 地址和 SSH 用户名"; return false
        }
        if config.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            config.sshPassword.isEmpty {
            lastError = "请填写 SSH 私钥或密码"; return false
        }
        if config.socksUser.isEmpty || config.socksPass.count < 8 {
            lastError = "SOCKS5 必须设置用户名，且密码至少 8 位"; return false
        }
        if !(1...65535).contains(config.sshPort) || !(1...65535).contains(config.remoteBindPort) {
            lastError = "端口无效"; return false
        }
        return true
    }

    func start() {
        lastError = ""
        guard !running, validate() else { return }
        saveConfig()
        keepAlive.start()
        let c = ProxyCore(config: config)
        c.start()
        core = c
        running = true
        UserDefaults.standard.set(true, forKey: "wasRunning")
    }

    func stop() {
        core?.stop()
        core = nil
        keepAlive.stop()
        running = false
        status = TunnelStatus()
        UserDefaults.standard.set(false, forKey: "wasRunning")
    }

    private func poll() {
        guard running, let core = core else { return }
        status = core.snapshot()
    }
}
