import SwiftUI

struct ServerListView: View {
    @StateObject private var session = SSHSession()
    @State private var host = ""
    @State private var port = "22"
    @State private var username = "root"
    @State private var password = ""
    @State private var showTerminal = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("服务器配置")) {
                    TextField("IP 地址或域名", text: $host)
                        .autocapitalization(.none)
                        .keyboardType(.asciiCapable)
                    TextField("端口 (默认 22)", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .autocapitalization(.none)
                    SecureField("密码", text: $password)
                }

                Section {
                    Button(action: {
                        let srv = SSHServer(
                            name: host.isEmpty ? "默认服务器" : host,
                            host: host,
                            port: Int(port) ?? 22,
                            username: username,
                            password: password
                        )
                        session.connect(server: srv)
                        showTerminal = true
                    }) {
                        Text("连接服务器")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .bold()
                    }
                    .disabled(host.isEmpty)
                }
            }
            .navigationTitle("服务器列表")
            .navigationDestination(isPresented: $showTerminal) {
                TerminalView(session: session)
            }
        }
    }
}
