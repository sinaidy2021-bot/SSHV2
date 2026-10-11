import Foundation
import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published var config = ProxyConfig()
    @Published var vpnStatus: NEVPNStatus = .invalid
    @Published var status = TunnelStatus()
    @Published var lastError = ""
    @Published var autoRestart = true

    private var manager: NETunnelProviderManager?
    private var timer: Timer?

    private var tunnelBundleID: String {
        Bundle.main.object(forInfoDictionaryKey: "TunnelBundleID") as? String ?? ""
    }

    init() {
        if let d = Keychain.load(),
           let c = try? Codec.decoder.decode(ProxyConfig.self, from: d) {
            config = c
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: - 配置

    func saveConfig() {
        if let d = try? Codec.encoder.encode(config) { Keychain.save(d) }
    }

    func pinHostKey() {
        guard !status.hostKeyFingerprint.isEmpty else { return }
        config.hostKeyFingerprint = status.hostKeyFingerprint
        saveConfig()
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

    // MARK: - VPN 管理

    func refresh() async {
        let list = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = list.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleID
        } ?? list.first
        if let m = manager { vpnStatus = m.connection.status }
    }

    func start() async {
        lastError = ""
        guard validate() else { return }
        saveConfig()
        do {
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = tunnelBundleID
            proto.serverAddress = config.sshHost
            proto.providerConfiguration = ["config": try Codec.encoder.encode(config)]
            m.protocolConfiguration = proto
            m.localizedDescription = "PhoneProxy"
            m.isEnabled = true
            m.onDemandRules = autoRestart ? [NEOnDemandRuleConnect()] : []
            m.isOnDemandEnabled = autoRestart
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            manager = m
            try m.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        guard let m = manager else { return }
        m.isOnDemandEnabled = false
        try? await m.saveToPreferences()
        m.connection.stopVPNTunnel()
    }

    // MARK: - 状态轮询

    private func poll() {
        guard let m = manager else { return }
        vpnStatus = m.connection.status
        guard vpnStatus == .connected,
              let session = m.connection as? NETunnelProviderSession else {
            if vpnStatus == .disconnected || vpnStatus == .invalid { status = TunnelStatus() }
            return
        }
        try? session.sendProviderMessage(Data("status".utf8)) { [weak self] data in
            guard let data = data,
                  let st = try? Codec.decoder.decode(TunnelStatus.self, from: data) else { return }
            Task { @MainActor in self?.status = st }
        }
    }
}
