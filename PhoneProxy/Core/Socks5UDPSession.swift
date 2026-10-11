import Foundation
import Network

public class Socks5UDPSession {
    private let tcpConnection: NWConnection
    private let udpListener: NWListener
    private var relayOutbounds: [String: NWConnection] = [:] // 针对各个外部目标的出站 UDP 连接

    public init(tcpConnection: NWConnection, udpListener: NWListener) {
        self.tcpConnection = tcpConnection
        self.udpListener = udpListener
    }

    public func start() {
        udpListener.newConnectionHandler = { [weak self] inboundConn in
            self?.handleInboundUDP(conn: inboundConn)
        }
    }

    private func handleInboundUDP(conn: NWConnection) {
        conn.start(queue: .global())
        receivePacket(conn: conn)
    }

    private func receivePacket(conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, let data = content, data.count > 10 else { return }
            
            // 解析 SOCKS5 UDP 头部: [RSV(2), FRAG(1), ATYP(1), DST.ADDR, DST.PORT, Payload]
            let frag = data[2]
            guard frag == 0x00 else {
                // 不支持 UDP 分片包处理
                self.receivePacket(conn: conn)
                return
            }
            
            let atyp = data[3]
            var offset = 4
            var targetHost: NWEndpoint.Host?
            
            if atyp == 0x01 { // IPv4
                let ipData = data.subdata(in: offset..<offset+4)
                let ipStr = ipData.map { String($0) }.joined(separator: ".")
                targetHost = NWEndpoint.Host(ipStr)
                offset += 4
            } else if atyp == 0x03 { // Domain
                let length = Int(data[offset])
                offset += 1
                if let domain = String(data: data.subdata(in: offset..<offset+length), encoding: .utf8) {
                    targetHost = NWEndpoint.Host(domain)
                }
                offset += length
            }
            
            guard let host = targetHost, data.count >= offset + 2 else { return }
            let portBytes = data.subdata(in: offset..<offset+2)
            let port = portBytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            
            let payload = data.subdata(in: offset..<data.count)
            let endpointKey = "\(host):\(port)"

            // 获取或创建发往实际目标服务器的 UDP 连接
            let outbound = self.relayOutbounds[endpointKey] ?? NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            self.relayOutbounds[endpointKey] = outbound
            
            outbound.stateUpdateHandler = { state in
                if case .ready = state {
                    outbound.send(content: payload, completion: .contentProcessed({ _ in }))
                }
            }
            if outbound.state == .setup {
                outbound.start(queue: .global())
            } else {
                outbound.send(content: payload, completion: .contentProcessed({ _ in }))
            }

            // 监听目标的回包，并重新加上 SOCKS5 头部回发给客户端
            outbound.receiveMessage { replyContent, _, _, _ in
                guard let replyContent = replyContent else { return }
                var responsePacket = Data([0x00, 0x00, 0x00]) // RSV + FRAG
                responsePacket.append(data.subdata(in: 3..<offset)) // 保持原目标地址头部
                responsePacket.append(replyContent)
                
                conn.send(content: responsePacket, completion: .contentProcessed({ _ in }))
            }

            self.receivePacket(conn: conn)
        }
    }

    public func stop() {
        udpListener.cancel()
        relayOutbounds.values.forEach { $0.cancel() }
        relayOutbounds.removeAll()
    }
}
