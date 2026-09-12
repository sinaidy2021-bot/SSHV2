import Foundation

struct SSHServer: Identifiable, Codable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String = "root"
    var password: String = ""
}

struct CommandBlock: Identifiable {
    let id = UUID()
    let timestamp = Date()
    var command: String
    var output: String = ""
    var isRunning: Bool = false
}
