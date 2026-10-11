import SwiftUI

struct ContentView: View {
    @StateObject private var c = ProxyService()
    @State private var showImporter = false

    var body: some View {
        NavigationView {
            Form {
                statusSection

                Section(header: Text("VPS（SSH）")) {
                    TextField("主机 / IP", text: $c.config.sshHost)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("SSH 端口", value: $c.config.sshPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $c.config.sshUser)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("VPS 监听端口（127.0.0.1）", value: $c.config.remoteBindPort, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("SSH 认证"),
                        footer: Text("推荐使用专用私钥。配置保存在系统钥匙串。")) {
                    TextEditor(text: $c.config.privateKey)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 110)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("从文件导入私钥") { showImporter = true }
                    SecureField("私钥口令（可选）", text: $c.config.keyPassphrase)
                    SecureField("或 SSH 密码（不推荐）", text: $c.config.sshPassword)
                }

                Section(header: Text("主机指纹"),
                        footer: Text("固定后，指纹变化将拒绝连接，防止中间人。")) {
                    if c.config.hostKeyFingerprint.isEmpty {
                        Text("尚未固定").foregroundColor(.orange)
                    } else {
                        Text(c.config.hostKeyFingerprint).font(.caption2).textSelection(.enabled)
                        Button("清除") { c.config.hostKeyFingerprint = ""; c.saveConfig() }
                    }
                    if !c.status.hostKeyFingerprint.isEmpty &&
                        c.status.hostKeyFingerprint != c.config.hostKeyFingerprint {
                        Text(c.status.hostKeyFingerprint).font(.caption2).textSelection(.enabled)
                        Button("固定当前连接的指纹") { c.pinHostKey() }
                    }
                }

                Section(header: Text("SOCKS5 认证（必填）")) {
                    TextField("用户名", text: $c.config.socksUser)
                        .autocapitalization(.none).disableAutocorrection(true)
                    TextField("密码（≥8 位）", text: $c.config.socksPass)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Button("生成随机账号密码") {
                        c.config.socksUser = "u" + Self.random(7)
                        c.config.socksPass = Self.random(20)
                    }
                }

                Section(header: Text("选项")) {
                    Toggle("出口强制走蜂窝数据", isOn: $c.config.forceCellularExit)
                    Toggle("SSH 隧道也强制走蜂窝", isOn: $c.config.forceCellularSSH)
                    Toggle("打开 App 时自动恢复运行", isOn: $c.autoResume)
                }

                Section(footer: Text(c.lastError).foregroundColor(.red)) {
                    if c.running {
                        Button("停止", role: .destructive) { c.stop() }
                    } else {
                        Button("保存并启动") { c.start() }
                    }
                }
            }
            .navigationTitle("PhoneProxy")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .plainText]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let s = try? String(contentsOf: url, encoding: .utf8) { c.config.privateKey = s }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section(header: Text("状态")) {
            row("运行", c.running ? "运行中" : "未运行", color: c.running ? .green : .secondary)
            if c.running {
                row("SSH 反向转发", linkText(c.status.state), color: linkColor(c.status.state))
                if !c.status.message.isEmpty {
                    Text(c.status.message).font(.footnote).foregroundColor(.secondary)
                }
                row("当前网络", netText(c.status.networkType))
                row("蜂窝可用", c.status.cellularAvailable ? "是" : "否")
                row("活动连接 / 累计", "\(c.status.activeConnections) / \(c.status.totalConnections)")
                row("上行 / 下行", "\(bytes(c.status.bytesUp)) / \(bytes(c.status.bytesDown))")
                row("重连次数", "\(c.status.reconnects)")
            }
        }
    }

    private func row(_ k: String, _ v: String, color: Color = .secondary) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(color) }
    }

    private func linkText(_ s: LinkState) -> String {
        switch s {
        case .online: return "在线"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .error: return "错误"
        case .idle: return "空闲"
        }
    }

    private func linkColor(_ s: LinkState) -> Color {
        switch s {
        case .online: return .green
        case .connecting, .reconnecting: return .orange
        case .error: return .red
        case .idle: return .secondary
        }
    }

    private func netText(_ t: String) -> String {
        switch t {
        case "wifi": return "Wi-Fi"
        case "cellular": return "蜂窝"
        case "wired": return "有线"
        case "none": return "无网络"
        default: return t
        }
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<n).compactMap { _ in chars.randomElement() })
    }
}
