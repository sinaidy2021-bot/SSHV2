import SwiftUI
import UIKit

struct TerminalView: View {
    @ObservedObject var session: SSHSession
    @State private var inputText: String = ""
    @FocusState private var isSystemKeyboardActive: Bool
    @State private var showCustomKeyboard: Bool = true
    
    @State private var quickCommands: [(title: String, cmd: String)] = [
        ("输入 k 菜单", "k"),
        ("面板管理 (x-ui)", "x-ui"),
        ("查看文件 (ls)", "ls -lh"),
        ("查看网络", "ip a"),
        ("磁盘空间", "df -h")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部快捷命令栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: {}) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                Text("添加")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(red: 26/255, green: 115/255, blue: 232/255))
                            .cornerRadius(6)
                        }

                        ForEach(quickCommands, id: \.title) { item in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                session.send(command: item.cmd)
                            }) {
                                Text(item.title)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color(UIColor.lightGray))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(red: 38/255, green: 38/255, blue: 40/255))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color(red: 18/255, green: 18/255, blue: 20/255))
                .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .bottom)

                // 终端卡片输出区
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal], showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(session.blocks) { block in
                                ExactReferenceCard(block: block)
                                    .id(block.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: session.blocks.count) { _, _ in
                        if let lastID = session.blocks.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                TextField("", text: $inputText)
                    .focused($isSystemKeyboardActive)
                    .opacity(0)
                    .frame(height: 1)

                // 底部键盘
                if showCustomKeyboard {
                    ExactCustomDockKeyboard(
                        inputText: $inputText,
                        isConnected: session.isConnected,
                        onSend: { text in session.send(command: text) },
                        onSendRaw: { raw in session.sendRaw(text: raw) },
                        onToggleNativeKeyboard: { isSystemKeyboardActive.toggle() },
                        onHideKeyboard: { showCustomKeyboard = false; isSystemKeyboardActive = false }
                    )
                } else {
                    Button(action: { showCustomKeyboard = true }) {
                        HStack {
                            Image(systemName: "keyboard")
                            Text("唤起快捷键盘")
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 24/255, green: 24/255, blue: 28/255))
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("终端控制台")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("断开") { session.disconnect() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 26/255, green: 115/255, blue: 232/255))
            }
        }
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct ExactReferenceCard: View {
    let block: CommandBlock

    private var cleanOutput: String {
        let pattern = #"\x1B\[[0-?]*[ -/]*[@-~]"#
        return block.output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("root@server~# \(block.command)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 65/255, green: 150/255, blue: 250/255))
                    .lineLimit(1)

                Spacer(minLength: 16)

                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIPasteboard.general.string = "\(block.command)\n\(cleanOutput)"
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("复制整段")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Color(UIColor.lightGray))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                }
            }

            if !cleanOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cleanOutput)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(red: 75/255, green: 225/255, blue: 100/255))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)

                    if let detectedUrl = extractUrl(from: cleanOutput) {
                        HStack {
                            Text("链接:").font(.system(size: 11)).foregroundColor(.gray)
                            Text(detectedUrl).font(.system(size: 10.5, design: .monospaced)).foregroundColor(Color.cyan).lineLimit(1)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = detectedUrl
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }) {
                                Image(systemName: "doc.on.doc.fill").font(.system(size: 11)).foregroundColor(Color.cyan)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(6)
                .background(Color(red: 10/255, green: 10/255, blue: 12/255))
                .cornerRadius(5)
            }
        }
        .padding(8)
        .background(Color(red: 20/255, green: 20/255, blue: 24/255))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func extractUrl(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        if let match = matches?.first, let range = Range(match.range, in: text) {
            return String(text[range])
        }
        return nil
    }
}

struct ExactCustomDockKeyboard: View {
    @Binding var inputText: String
    var isConnected: Bool
    var onSend: (String) -> Void
    var onSendRaw: (String) -> Void
    var onToggleNativeKeyboard: () -> Void
    var onHideKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onHideKeyboard()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.down")
                        Text("收起")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(5)
                }

                HStack(spacing: 4) {
                    Circle().fill(isConnected ? Color.green : Color.red).frame(width: 6, height: 6)
                    Text(isConnected ? "已在线" : "离线").font(.system(size: 11)).foregroundColor(.gray)
                }

                if !inputText.isEmpty {
                    Text(inputText)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    if !inputText.isEmpty {
                        onSend(inputText)
                        inputText = ""
                    } else {
                        onSendRaw("\n")
                    }
                }) {
                    Text("回车")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 28)
                        .background(Color(red: 26/255, green: 115/255, blue: 232/255))
                        .cornerRadius(5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            HStack(spacing: 4) {
                ForEach(["1", "2", "3", "4", "5", "k"], id: \.self) { key in
                    StandardKeyButton(title: key) { inputText.append(key) }
                }
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSendRaw("\u{0003}")
                }) {
                    Text("Ctrl+C")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color(red: 220/255, green: 53/255, blue: 69/255))
                        .cornerRadius(5)
                }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 4) {
                ForEach(["6", "7", "8", "9", "0", "-"], id: \.self) { key in
                    StandardKeyButton(title: key) { inputText.append(key) }
                }
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSendRaw("\u{001B}")
                }) {
                    Text("ESC")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color(red: 245/255, green: 130/255, blue: 32/255))
                        .cornerRadius(5)
                }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 4) {
                StandardKeyButton(title: "空格") { inputText.append(" ") }
                StandardKeyButton(title: "x-ui") { inputText.append("x-ui") }
                StandardKeyButton(title: "88") { inputText.append("88") }
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !inputText.isEmpty { inputText.removeLast() } else { onSendRaw("\u{0008}") }
                }) {
                    HStack(spacing: 1) {
                        Image(systemName: "delete.left")
                        Text("退格")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color(red: 50/255, green: 50/255, blue: 54/255))
                    .cornerRadius(5)
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onToggleNativeKeyboard()
                }) {
                    VStack(spacing: 0) {
                        Text("Aa 全")
                        Text("键盘")
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color(red: 60/255, green: 60/255, blue: 66/255))
                    .cornerRadius(5)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 20)
        .background(Color(red: 24/255, green: 24/255, blue: 28/255).ignoresSafeArea(edges: .bottom))
        .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .top)
    }
}

struct StandardKeyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color(red: 50/255, green: 50/255, blue: 54/255))
                .cornerRadius(5)
        }
    }
}
