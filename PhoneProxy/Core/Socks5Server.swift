import Foundation
import Network

public class Socks5Server {
    private var tcpListener: NWListener?
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.phoneproxy.socks5", attributes: .concurrent)
    
    // 维护每个 TCP 控制连接对应的 UDP 会话
    private var udpSessions: [ObjectIdentifier: Socks5UDPSession] = [:]
    private let sessionLock = NSLock()

    public init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    // 处理请求命令阶段
    private func handleCommand(connection: NWConnection, data: Data) {
        guard data.count >= 4 else { return }
        let cmd = data[1] // 0x01: CONNECT, 0x03: UDP ASSOCIATE
        
        switch cmd {
        case 0x01:
            // 现有的 TCP CONNECT 处理逻辑
            handleTCPConnect(connection: connection, data: data)
            
        case 0x03:
            // 支持 UDP ASSOCIATE
            handleUDPAssociate(tcpConnection: connection, requestData: data)
            
        default:
            // 0x07: Command not supported
            sendReply(connection: connection, rep: 0x07)
        }
    }

    private func handleUDPAssociate(tcpConnection: NWConnection, requestData: Data) {
        do {
            // 随机或动态分配一个本地 UDP 端口用于接收该会话的 UDP 数据包
            let udpListener = try NWListener(using: .udp, on: .any)
            let session = Socks5UDPSession(tcpConnection: tcpConnection, udpListener: udpListener)
            
            let key = ObjectIdentifier(tcpConnection)
            sessionLock.lock()
            udpSessions[key] = session
            sessionLock.unlock()

            udpListener.stateUpdateHandler = { [weak self, weak tcpConnection] state in
                guard let self = self, let tcpConn = tcpConnection else { return }
                if case .ready = state {
                    if let assignedPort = udpListener.port?.rawValue {
                        // 回复客户端 SOCKS 握手成功 (REP: 0x00, BND.ADDR: 127.0.0.1, BND.PORT: assignedPort)
                        self.sendUDPAssociateSuccess(connection: tcpConn, port: assignedPort)
                        session.start()
                    }
                }
            }
            
            // 监听 TCP 控制连接生命周期，控制连接关闭时释放 UDP 监听和资源
            tcpConnection.stateUpdateHandler = { [weak self, weak tcpConnection] state in
                guard let self = self, let tcpConn = tcpConnection else { return }
                if state == .cancelled || state == .failed(nil) {
                    self.sessionLock.lock()
                    let removed = self.udpSessions.removeValue(forKey: ObjectIdentifier(tcpConn))
                    self.sessionLock.unlock()
                    removed?.stop()
                }
            }

            udpListener.start(queue: queue)
        } catch {
            sendReply(connection: tcpConnection, rep: 0x01) // General SOCKS server failure
        }
    }

    private func sendUDPAssociateSuccess(connection: NWConnection, port: UInt16) {
        var reply = Data([0x05, 0x00, 0x00, 0x01]) // VER=5, REP=0, RSV=0, ATYP=1 (IPv4)
        reply.append(contentsOf: [127, 0, 0, 1])     // BND.ADDR: 127.0.0.1
        var bigEndianPort = port.bigEndian
        reply.append(Data(bytes: &bigEndianPort, count: 2))
        
        connection.send(content: reply, completion: .contentProcessed({ _ in }))
    }
    
    private func sendReply(connection: NWConnection, rep: UInt8) {
        let reply = Data([0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        connection.send(content: reply, completion: .contentProcessed({ _ in }))
    }
}
