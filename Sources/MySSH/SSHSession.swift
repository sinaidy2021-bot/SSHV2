import Foundation
import Citadel
import NIOCore

@MainActor
class SSHSession: ObservableObject {
    @Published var isConnected = false
    @Published var blocks: [CommandBlock] = []
    @Published var statusMessage: String = "未连接"
    
    private var client: SSHClient?
    private var keepAliveTimer: Timer?

    func connect(server: SSHServer) {
        self.statusMessage = "正在连接 \(server.host)..."
        Task {
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
                self.startKeepAlive()
                self.appendNotice("连接成功，交互式会话已建立。")
            } catch {
                self.statusMessage = "连接失败: \(error.localizedDescription)"
                self.isConnected = false
            }
        }
    }

    func disconnect() {
        stopKeepAlive()
        Task {
            try? await client?.close()
            self.client = nil
            self.isConnected = false
            self.statusMessage = "已手动断开"
        }
    }

    func send(command: String) {
        guard isConnected, let client = self.client else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let blockIndex = blocks.count
        blocks.append(CommandBlock(command: trimmed, output: "", isRunning: true))

        Task {
            do {
                let outputStream = try await client.executeCommandStream(trimmed)
                for try await chunk in outputStream {
                    var chunkBuffer: ByteBuffer?
                    switch chunk {
                    case .stdout(let buffer):
                        chunkBuffer = buffer
                    case .stderr(let buffer):
                        chunkBuffer = buffer
                    }
                    if let buffer = chunkBuffer {
                        let text = String(buffer: buffer)
                        self.blocks[blockIndex].output += text
                    }
                }
                self.blocks[blockIndex].isRunning = false
            } catch {
                self.blocks[blockIndex].output += "\n执行出错: \(error.localizedDescription)"
                self.blocks[blockIndex].isRunning = false
            }
        }
    }

    private func appendNotice(_ msg: String) {
        blocks.append(CommandBlock(command: "系统消息", output: msg, isRunning: false))
    }

    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isConnected else { return }
                _ = try? await self.client?.executeCommand("echo -n ''")
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
}
