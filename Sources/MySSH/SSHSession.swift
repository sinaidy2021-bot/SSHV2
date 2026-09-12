import Foundation
import Citadel
import NIOCore

@MainActor
class SSHSession: ObservableObject {
    @Published var isConnected = false
    @Published var blocks: [CommandBlock] = []
    @Published var statusMessage: String = "未连接"
    
    private var client: SSHClient?
    private var shellChannel: SSHChannel?
    private var shellStream: SSHChannelStream<ByteBuffer>?
    
    private var keepAliveTask: Task<Void, Never>?

    func connect(server: SSHServer) {
        self.statusMessage = "正在连接 \(server.host)..."
        Task { @MainActor in
            do {
                let client = try await SSHClient.connect(
                    host: server.host,
                    port: server.port,
                    authenticationMethod: .passwordBased(username: server.username, password: server.password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                self.client = client
                self.isConnected = true
                self.statusMessage = "已连接: \(server.host)"
                
                let shell = try await client.requestSessionChannel()
                try await shell.requestPseudoTerminal(
                    termType: "xterm-256color",
                    terminalWindowSize: .init(width: 80, height: 24)
                )
                
                let stream = try await shell.requestShell()
                self.shellChannel = shell
                self.shellStream = stream
                
                self.startKeepAlive()
                self.appendNotice("连接成功，交互式 PTY 终端已建立。")
                self.listenToShell()
                
            } catch {
                self.statusMessage = "连接失败: \(error.localizedDescription)"
                self.isConnected = false
            }
        }
    }

    func disconnect() {
        stopKeepAlive()
        Task { @MainActor in
            try? await shellChannel?.close()
            try? await client?.close()
            self.shellChannel = nil
            self.shellStream = nil
            self.client = nil
            self.isConnected = false
            self.statusMessage = "已手动断开"
        }
    }

    func send(command: String) {
        guard isConnected, let stream = self.shellStream else { return }
        let text = command + "\n"
        
        blocks.append(CommandBlock(command: command, output: "", isRunning: false))
        
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            try? await stream.write(buffer)
        }
    }
    
    func sendRaw(text: String) {
        guard isConnected, let stream = self.shellStream else { return }
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            try? await stream.write(buffer)
        }
    }

    private func listenToShell() {
        guard let stream = self.shellStream else { return }
        Task { @MainActor in
            do {
                for try await chunk in stream {
                    var buffer: ByteBuffer?
                    switch chunk {
                    case .stdout(let buf): buffer = buf
                    case .stderr(let buf): buffer = buf
                    }
                    if let buf = buffer {
                        let text = String(buffer: buf)
                        let cleanText = text.replacingOccurrences(of: "\r", with: "")
                        
                        if let lastIndex = self.blocks.indices.last {
                            self.blocks[lastIndex].output += cleanText
                        } else {
                            self.blocks.append(CommandBlock(command: "Shell", output: cleanText, isRunning: false))
                        }
                    }
                }
            } catch {
                self.appendNotice("Shell 连接异常断开。")
                self.disconnect()
            }
        }
    }

    private func appendNotice(_ msg: String) {
        blocks.append(CommandBlock(command: "系统消息", output: msg, isRunning: false))
    }

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self = self, self.isConnected else { break }
                self.sendRaw(text: "")
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }
}
