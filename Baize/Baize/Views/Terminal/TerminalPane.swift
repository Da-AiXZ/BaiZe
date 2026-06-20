import SwiftUI

// MARK: - TerminalPane (主容器)

/// 终端面板主容器 — 嵌入 WorkspacePane 底部
///
/// 条件渲染折叠/展开态：
/// - 折叠态（36pt）：仅显示 TerminalTitleBar
/// - 展开态（35% 高度）：TerminalTitleBar + TerminalOutputArea + TerminalInputBar
///
/// Bug 5 动画隔离：终端展开/折叠由 ViewModel.toggleExpanded() 的 withAnimation 驱动，
/// ContentView 中 HStack 的 .transaction { t in t.animation = nil } 阻止动画传导。
///
/// Bug 6 长输出渲染：输出区使用 LazyVStack，仅渲染可见行。
struct TerminalPane: View {
    @ObservedObject var viewModel: TerminalViewModel

    /// WorkspacePane 的总可用高度（由 GeometryReader 传入）
    /// 展开态高度 = availableHeight * 0.35，折叠态 = 36pt
    let availableHeight: CGFloat

    /// 当前面板高度
    private var paneHeight: CGFloat {
        if viewModel.isExpanded {
            // 展开态：35% 总高度，最低 150pt 防止过小
            return max(availableHeight * 0.35, 150)
        } else {
            // 折叠态：仅标题栏高度
            return 36
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（始终显示）
            TerminalTitleBar(viewModel: viewModel)

            // 展开态：输出区 + 输入框
            if viewModel.isExpanded {
                Divider()
                    .background(Color.baizeBorder)

                TerminalOutputArea(viewModel: viewModel)

                Divider()
                    .background(Color.baizeBorder)

                TerminalInputBar(viewModel: viewModel)
            }
        }
        .frame(height: paneHeight)
        .frame(maxWidth: .infinity)
        .background(Color.baizeBackground)
        .clipped()
    }
}

// MARK: - Terminal Title Bar

/// 终端标题栏 — 图标 + 标题 + 命令计数 + 操作按钮
/// 点击标题栏切换展开/折叠
private struct TerminalTitleBar: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack(spacing: 8) {
            // 终端图标
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.baizeAccent)

            // 标题
            Text("终端")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.baizeTextPrimary)

            // 命令计数
            if !viewModel.commandHistory.isEmpty {
                Text("\(viewModel.commandHistory.count) 条命令")
                    .font(.system(size: 11))
                    .foregroundColor(.baizeTextSecondary)
            }

            // 执行中状态指示
            if viewModel.isExecuting {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                Text("执行中...")
                    .font(.system(size: 11))
                    .foregroundColor(.baizeAccent)
            }

            Spacer()

            // T04: 停止按钮（执行中显示）
            if viewModel.isExecuting {
                Button(action: {
                    viewModel.cancelExecution()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.baizeError)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.baizeError.opacity(0.15))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            // 清屏按钮
            Button(action: {
                viewModel.clear()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.baizeTextSecondary)
            }
            .buttonStyle(.plain)

            // 折叠/展开按钮
            Button(action: {
                viewModel.toggleExpanded()
            }) {
                Image(systemName: viewModel.isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12))
                    .foregroundColor(.baizeTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.baizeCardBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleExpanded()
        }
    }
}

// MARK: - Terminal Output Area

/// 终端输出区 — LazyVStack + ScrollViewReader
///
/// Bug 6 长输出渲染：使用 LazyVStack（非 VStack），仅渲染可见行，
/// 避免长输出（如 grep -r）数千行导致卡顿。
///
/// 自动滚底：outputLines.count 变化时滚动到最后一条。
/// 颜色按 LineType 区分：command/output → baizeTextPrimary，error → baizeError，
/// system → baizeTextSecondary。
///
/// T04: 长按输出区 contextMenu 复制全部文本。
private struct TerminalOutputArea: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.outputLines) { line in
                        TerminalLineView(line: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color.baizeBackground)
            // 自动滚到底部 — 新输出到达时
            .onChange(of: viewModel.outputLines.count) { _ in
                if let lastId = viewModel.outputLines.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        // T04: 长按输出区 → 复制全部文本
        .contextMenu {
            Button(action: {
                let allText = viewModel.outputLines.map { line in
                    line.content
                }.joined(separator: "\n")
                UIPasteboard.general.string = allText
            }) {
                Label("复制全部输出", systemImage: "doc.on.doc")
            }

            Button(action: {
                viewModel.clear()
            }) {
                Label("清屏", systemImage: "trash")
            }
        }
    }
}

// MARK: - Terminal Line View

/// 单行终端输出渲染 — 根据 LineType 和 CommandSource 显示不同样式
///
/// 颜色规范（架构设计 8.1 节）：
///   .command  → baizeTextPrimary（前缀 "$ "）
///   .output   → baizeTextPrimary（支持 ANSI 颜色解析）
///   .error    → baizeError
///   .system   → baizeTextSecondary
///
/// T04: Agent 命令行显示 [Agent] 标签（baizeWarning 色）
/// T04: 输出行使用 ANSIParser 解析 ANSI 转义码着色
private struct TerminalLineView: View {
    let line: TerminalLine

    /// 行文本颜色（基于 LineType）
    private var textColor: Color {
        switch line.type {
        case .command:  return .baizeTextPrimary
        case .output:   return .baizeTextPrimary
        case .error:    return .baizeError
        case .system:   return .baizeTextSecondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // T04: Agent 命令行显示 [Agent] 标签
            if line.source == .agent && line.type == .command {
                Text("[Agent]")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.baizeWarning)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.baizeWarning.opacity(0.15))
                    .cornerRadius(3)
            }

            // 输出行文本
            // T04: .output 类型使用 ANSIParser 解析 ANSI 颜色码
            if line.type == .output && containsANSICodes(line.content) {
                Text(ANSIParser.parse(line.content))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line.content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 检测文本是否包含 ANSI 转义码
    private func containsANSICodes(_ text: String) -> Bool {
        text.contains("\u{001B}[")
    }
}

// MARK: - Terminal Input Bar

/// 终端输入栏 — $ 提示符 + 工作目录 + TextField
///
/// T04: 上下键历史导航（.onKeyPress 需 iOS 17+，iOS 16 降级为按钮）
/// 回车执行命令，清空输入框
private struct TerminalInputBar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    /// 简化工作目录显示（将 BaizePath.projectRoot 替换为 ~）
    private var displayWorkingDir: String {
        let root = BaizePath.projectRoot
        if viewModel.currentWorkingDir == root {
            return "~/Baize"
        } else if viewModel.currentWorkingDir.hasPrefix(root) {
            let suffix = String(viewModel.currentWorkingDir.dropFirst(root.count))
            return "~/Baize/\(suffix)"
        } else {
            return viewModel.currentWorkingDir
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // $ 提示符
            Text("$")
                .font(.system(size: 13, design: .monospaced).bold())
                .foregroundColor(.baizeAccent)

            // 工作目录路径
            Text(displayWorkingDir)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.baizeTextSecondary)
                .lineLimit(1)

            // 输入框
            // T04: 上下键历史导航需 iOS 17+（.onKeyPress API）
            // iOS 16 降级为历史导航按钮
            if #available(iOS 17.0, *) {
                TextField("输入命令...", text: $inputText, axis: .horizontal)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.baizeTextPrimary)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        executeCommand()
                    }
                    .onKeyPress(.upArrow) {
                        if let cmd = viewModel.previousCommand() {
                            inputText = cmd
                        }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if let cmd = viewModel.nextCommand() {
                            inputText = cmd
                        }
                        return .handled
                    }
            } else {
                // iOS 16: 无 .onKeyPress，使用历史导航按钮
                TextField("输入命令...", text: $inputText, axis: .horizontal)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.baizeTextPrimary)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        executeCommand()
                    }

                // 历史导航按钮（上/下）
                Button(action: {
                    if let cmd = viewModel.previousCommand() {
                        inputText = cmd
                    }
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10))
                        .foregroundColor(.baizeTextSecondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    if let cmd = viewModel.nextCommand() {
                        inputText = cmd
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.baizeTextSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.baizeInputFieldBackground)
        .onTapGesture {
            // T04-1 fix: 点击输入栏聚焦，替代 onAppear 自动聚焦（避免面板展开时抢焦）
            isFocused = true
        }
    }

    /// 执行输入的命令并清空输入框
    private func executeCommand() {
        let command = inputText
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        inputText = ""
        viewModel.execute(command: command, source: .user)
    }
}
