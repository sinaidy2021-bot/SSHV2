import SwiftUI
import UIKit

struct TerminalView: View {
    @ObservedObject var session: SSHSession
    @State private var inputText: String = ""
    @FocusState private var isSystemKeyboardActive: Bool
    @State private var showCustomKeyboard: Bool = true
    
    // 快捷命令列表
    @State private var quickCommands = [
        "输入 k 菜单": "k",
        "面板管理 (x-ui)": "x-ui",
        "查看文件 (ls)": "ls -lh",
        "磁盘空间": "df -h",
        "查看网络": "ip a"
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. 顶部快捷命令滑动栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: {
                            // 预留添加自定义快捷命令
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("添加")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(red: 26/255, green: 115/255, blue: 232/255))
                            .cornerRadius(6)
                        }

                        ForEach(Array(quickCommands.keys.sorted()), id: \.self) { title in
                            Button(action: {
                                if let cmd = quickCommands[title] {
                                    triggerHaptic(.rigid)
                                    session.send(command: cmd)
                                }
                            }) {
                                Text(title)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(Color(UIColor.lightGray))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color(red: 38/255, green: 38/255, blue: 40/255))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(red: 18/255, green: 18/255, blue: 20/255))
                .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .bottom)

                // 2. 终端卡片输出区
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(session.blocks) { block in
                                ExactReferenceCard(block: block)
                                    .id(block.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: session.blocks.count) { _, _ in
                        if let lastID = session.blocks.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                // 隐藏式系统文本输入组件
                TextField("", text: $inputText)
                    .focused($isSystemKeyboardActive)
                    .opacity(0)
                    .frame(height: 1)

                // 3. 底部专属软键盘
                if showCustomKeyboard {
                    ExactCustomDockKeyboard(
                        inputText: $inputText,
                        isConnected: session.isConnected,
                        onSend: { text in
                            session.send(command: text)
                        },
                        onSendRaw: { raw in
                            session.sendRaw(text: raw)
                        },
                        onToggleNativeKeyboard: {
                            isSystemKeyboardActive.toggle()
                        },
                        onHideKeyboard: {
                            showCustomKeyboard = false
                            isSystemKeyboardActive = false
                        }
                    )
                } else {
                    // 键盘被收起时，底部留一个轻触呼出条
                    Button(action: { showCustomKeyboard = true }) {
                        HStack {
                            Image(systemName: "keyboard")
                            Text("唤起快捷键盘")
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
                Button("断开") {
                    session.disconnect()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 26/255, green: 115/255, blue: 232/255))
            }
        }
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// 命令与回显段落卡片
struct ExactReferenceCard: View {
    let block: CommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 命令行与整段复制
            HStack {
                Text("root@server~# \(block.command)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 30/255, green: 144/255, blue: 255/255))
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIPasteboard.general.string = "\(block.command)\n\(block.output)"
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("复制整段")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                }
            }

            // 输出文本区（带绿色荧光等宽字体与智能单独复制）
            if !block.output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.output)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 50/255, green: 205/255, blue: 50/255))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    // 智能提取：检测包含 URL、用户名或密码等，提供单项一键复制小浮钮
                    if let detectedUrl = extractUrl(from: block.output) {
                        HStack {
                            Text("链接:")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                            Text(detectedUrl)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(red: 30/255, green: 144/255, blue: 255/255))
                                .lineLimit(1)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = detectedUrl
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.cyan)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.8))
                .cornerRadius(6)
            }
        }
        .padding(10)
        .background(Color(red: 18/255, green: 18/255, blue: 22/255))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
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

// 专属软键盘（完全还原你的截图结构）
struct ExactCustomDockKeyboard: View {
    @Binding var inputText: String
    var isConnected: Bool
    var onSend: (String) -> Void
    var onSendRaw: (String) -> Void
    var onToggleNativeKeyboard: () -> Void
    var onHideKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // 控制栏：收起、已在线、回车
            HStack {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onHideKeyboard()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.down")
                        Text("收起")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(isConnected ? "已在线" : "离线")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.leading, 6)

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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 70, height: 32)
                        .background(Color(red: 26/255, green: 115/255, blue: 232/255))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            // 第一行：1 2 3 4 5 k Ctrl+C
            HStack(spacing: 6) {
                ForEach(["1", "2", "3", "4", "5", "k"], id: \.self) { key in
                    StandardKeyButton(title: key) {
                        inputText.append(key)
                    }
                }
                // Ctrl+C (红底色)
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSendRaw("\u{0003}")
                }) {
                    Text("Ctrl+C")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color(red: 220/255, green: 53/255, blue: 69/255))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)

            // 第二行：6 7 8 9 0 - ESC
            HStack(spacing: 6) {
                ForEach(["6", "7", "8", "9", "0", "-"], id: \.self) { key in
                    StandardKeyButton(title: key) {
                        inputText.append(key)
                    }
                }
                // ESC (橙底色)
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSendRaw("\u{001B}")
                }) {
                    Text("ESC")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color(red: 245/255, green: 130/255, blue: 32/255))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)

            // 第三行：空格 x-ui 88 ⌫退格 Aa全键盘
            HStack(spacing: 6) {
                StandardKeyButton(title: "空格") {
                    inputText.append(" ")
                }

                StandardKeyButton(title: "x-ui") {
                    inputText.append("x-ui")
                }

                StandardKeyButton(title: "88") {
                    inputText.append("88")
                }

                // 退格
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !inputText.isEmpty {
                        inputText.removeLast()
                    } else {
                        onSendRaw("\u{0008}") // 发送终端回退符
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "delete.left")
                        Text("退格")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Color(red: 50/255, green: 50/255, blue: 54/255))
                    .cornerRadius(6)
                }

                // 唤起原生键盘
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onToggleNativeKeyboard()
                }) {
                    VStack(spacing: 1) {
                        Text("Aa 全")
                        Text("键盘")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Color(red: 60/255, green: 60/255, blue: 66/255))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(red: 28/255, green: 28/255, blue: 32/255))
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
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color(red: 50/255, green: 50/255, blue: 54/255))
                .cornerRadius(6)
        }
    }
}
