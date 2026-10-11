import Foundation

/// 配置：由 App 写入 NETunnelProviderProtocol.providerConfiguration，扩展启动时读取。
struct ProxyConfig: Codable, Equatable {
    var sshHost = ""
    var sshPort = 22
    var sshUser = ""
    var sshPassword = ""
    var privateKey = ""            // OpenSSH / PEM 私钥全文
    var keyPassphrase = ""
    var hostKeyFingerprint = ""    // "SHA256:xxxx"，留空表示未固定
    var remoteBindPort = 11080     // VPS 上 127.0.0.1 监听的端口
    var socksUser = ""
    var socksPass = ""
    var forceCellularExit = true   // 出口流量强制走蜂窝
    var forceCellularSSH = false   // SSH 隧道本身也强制走蜂窝
    var keepaliveSeconds = 15
}

enum LinkState: String, Codable {
    case idle, connecting, online, reconnecting, error
}

struct TunnelStatus: Codable {
    var state: LinkState = .idle
    var message = ""
    var networkType = "unknown"    // wifi / cellular / wired / other / none
    var cellularAvailable = false
    var activeConnections = 0
    var totalConnections = 0
    var bytesUp: UInt64 = 0        // 手机 -> 互联网
    var bytesDown: UInt64 = 0      // 互联网 -> 手机
    var reconnects = 0
    var lastChange = Date()
    var hostKeyFingerprint = ""
}

enum Codec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
