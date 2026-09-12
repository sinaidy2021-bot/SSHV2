import SwiftUI
import UIKit

struct TerminalView: View {
    @ObservedObject var session: SSHSession
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏状态
            HStack {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if session.isConnected {
                    Button("断开连接") {
                        session.disconnect()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))

            // 段落回显展示区
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.blocks) { block in
                            CommandBlockCard(block: block)
                                .id(block.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(UIColor.systemBackground))
                .onChange(of: session.blocks.count) { _ in
                    if let lastID = session.blocks.last?.id {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }

            // 底部专用软键盘
            CustomSSHKeyboard(
                inputText: $inputText,
                isFocused: $isInputFocused,
                onExecute: {
                    session.send(command: inputText)
                    inputText = ""
                }
            )
        }
        .navigationTitle("终端控制台")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CommandBlockCard: View {
    let block: CommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$ \(block.command)")
                    .font(.system(.subheadline, design: .monospaced))
                    .bold()
                    .foregroundColor(.green)
                Spacer()
                Menu {
                    Button("复制整段") {
                        UIPasteboard.general.string = "$ \(block.command)\n\(block.output)"
                    }
                    Button("仅复制命令") {
                        UIPasteboard.general.string = block.command
                    }
                    Button("仅复制输出") {
                        UIPasteboard.general.string = block.output
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            if block.isRunning {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.6)
                    Text("执行中...").font(.caption2).foregroundColor(.secondary)
                }
            } else if !block.output.isEmpty {
                Text(block.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Color(UIColor.label))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}

struct CustomSSHKeyboard: View {
    @Binding var inputText: String
    var isFocused: FocusState<Bool>.Binding
    var onExecute: () -> Void

    let numbers = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    var body: some View {
        VStack(spacing: 5) {
            // 输入输入预览框
            HStack {
                TextField("点击唤起输入或按下方快捷键...", text: $inputText)
                    .focused(isFocused)
                    .font(.system(.subheadline, design: .monospaced))
                if !inputText.isEmpty {
                    Button(action: { inputText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(6)
            .padding(.horizontal, 8)

            // 数字行 (0-9)
            HStack(spacing: 4) {
                ForEach(numbers, id: \.self) { num in
                    Button(action: { inputText.append(num) }) {
                        Text(num)
                            .font(.system(.subheadline, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(5)
                    }
                }
            }
            .padding(.horizontal, 8)

            // 操作行：左下角收键盘、一键粘贴、常用字符、右下角回车
            HStack(spacing: 6) {
                // 左下角隐藏键盘
                Button(action: { isFocused.wrappedValue = false }) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(width: 44, height: 36)
                        .background(Color(UIColor.systemGray4))
                        .cornerRadius(6)
                }

                // 一键粘贴
                Button(action: {
                    if let clip = UIPasteboard.general.string {
                        inputText.append(clip)
                    }
                }) {
                    Text("粘贴")
                        .font(.caption)
                        .bold()
                        .frame(width: 44, height: 36)
                        .background(Color(UIColor.systemGray5))
                        .cornerRadius(6)
                }

                Button("/") { inputText.append("/") }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(6)

                Button("-") { inputText.append("-") }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(6)

                Button("空格") { inputText.append(" ") }
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(6)

                // 右下角执行
                Button(action: onExecute) {
                    HStack(spacing: 2) {
                        Text("执行")
                        Image(systemName: "return")
                    }
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                    .frame(width: 76, height: 36)
                    .background(Color.blue)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }
}
