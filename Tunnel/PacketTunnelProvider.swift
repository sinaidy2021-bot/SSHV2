import NetworkExtension

/// Packet Tunnel 扩展只是“保活壳”：建立一个不接管任何流量的虚拟网卡，
/// 让扩展进程在后台持续运行；真正的工作由 ProxyCore 完成。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var core: ProxyCore?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?["config"] as? Data,
              let cfg = try? Codec.decoder.decode(ProxyConfig.self, from: data) else {
            completionHandler(NSError(domain: "PhoneProxy", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "缺少配置"]))
            return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: ["10.255.255.2"], subnetMasks: ["255.255.255.252"])
        // 仅一条指向虚拟网段本身的路由 => 不会劫持设备其他流量
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.255.0",
                                         subnetMask: "255.255.255.252")]
        settings.ipv4Settings = v4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }
            self.drainPackets()
            let core = ProxyCore(config: cfg)
            self.core = core
            core.start()
            completionHandler(nil)
        }
    }

    private func drainPackets() {
        packetFlow.readPackets { [weak self] _, _ in
            self?.drainPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        core?.stop()
        core = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let core = core,
              let data = try? Codec.encoder.encode(core.snapshot()) else {
            completionHandler?(nil)
            return
        }
        completionHandler?(data)
    }
}
