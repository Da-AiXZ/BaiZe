import SwiftUI

/// 消息气泡视图 — 区分文本消息、工具调用、工具结果、错误消息
/// 文本消息：用户（蓝色右对齐）/ Agent（灰色左对齐）
/// 工具调用：显示工具名 + 参数摘要 + 执行状态（pending/executing/completed/denied）
/// 错误消息：红色警示样式
struct MessageBubble: View {
    let message: DisplayMessage
    /// T05: 长消息折叠/展开状态（纯 UI 状态，铁律 #10：不存入 Message）
    let isExpanded: Bool
    /// T05: 切换折叠/展开状态的回调
    let toggleExpansion: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(content: message.content, timestamp: message.timestamp)
        case .assistant:
            AssistantMessageBubble(
                content: message.content,
                timestamp: message.timestamp,
                isExpanded: isExpanded,
                toggleExpansion: toggleExpansion
            )
        case .toolCall:
            if let toolCall = message.toolCall, let status = message.toolStatus {
                ToolCallBubble(
                    toolCall: toolCall,
                    status: status,
                    result: message.toolResult,
                    denialReason: message.denialReason
                )
            }
        case .error:
            ErrorMessageBubble(content: message.content, timestamp: message.timestamp)
        case .system:
            // P0-2: 压缩提示等系统消息 — 灰色卡片,居中,📦 图标
            SystemMessageBubble(content: message.content)
        }
    }
}

// MARK: - User Message Bubble

/// 用户消息气泡 — 蓝色，右对齐
private struct UserMessageBubble: View {
    let content: String
    let timestamp: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 40)

            VStack(alignment: .trailing, spacing: 4) {
                Text(content)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.baizeAccent)
                    .cornerRadius(12)

                Text(timestamp.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Circle()
                .fill(Color.blue)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                )
        }
    }
}

// MARK: - Assistant Message Bubble

/// Agent 文本消息气泡 — 深色背景，左对齐
/// T05: Bug 6 长内容折叠/展开 + 分段渲染优化
private struct AssistantMessageBubble: View {
    let content: String
    let timestamp: Date
    /// T05: 折叠/展开状态（由 ChatMessageList 管理，通过 Binding 传递）
    let isExpanded: Bool
    /// T05: 切换折叠/展开的回调
    let toggleExpansion: () -> Void

    /// 折叠阈值：超过 2000 字符或 50 行的消息触发折叠（验收标准 #3）
    private let collapseCharThreshold: Int = 2000
    private let collapseLineThreshold: Int = 50
    /// Bug 6 fix: 折叠后预览的最大字符数（确保折叠后内容不会太长）
    private let collapsedMaxChars: Int = 800
    /// Bug 6 fix: 折叠后预览的最大行数
    private let collapsedMaxLines: Int = 20
    /// 分段渲染阈值：超过 5000 字符的消息按段落分割渲染
    private let segmentCharThreshold: Int = 5000

    /// 是否应折叠（超过阈值）
    private var shouldCollapse: Bool {
        content.count > collapseCharThreshold
            || content.components(separatedBy: "\n").count > collapseLineThreshold
    }

    /// Bug 6 fix: 折叠时显示的内容
    /// 同时限制行数和字符数，在段落边界（\n\n）截断，确保折叠后 ≤ 800 字左右
    private var collapsedContent: String {
        let lines = content.components(separatedBy: "\n")

        // 先按行数截断到 collapsedMaxLines 行
        var previewLines = Array(lines.prefix(collapsedMaxLines))
        var preview = previewLines.joined(separator: "\n")

        // 如果超过字符限制，按段落边界截断
        if preview.count > collapsedMaxChars {
            // 尝试在段落边界（\n\n）截断
            let paragraphs = preview.components(separatedBy: "\n\n")
            var truncated = ""
            for paragraph in paragraphs {
                let candidate = truncated.isEmpty ? paragraph : truncated + "\n\n" + paragraph
                if candidate.count <= collapsedMaxChars {
                    truncated = candidate
                } else {
                    break
                }
            }
            // 如果连第一个段落都超限，按字符硬截断
            if truncated.isEmpty {
                let endIndex = preview.index(preview.startIndex, offsetBy: collapsedMaxChars, limitedBy: preview.endIndex) ?? preview.endIndex
                truncated = String(preview[preview.startIndex..<endIndex])
            }
            preview = truncated
            previewLines = preview.components(separatedBy: "\n")
        }

        // 添加省略提示（如果原始内容比预览长）
        if content.count > preview.count || lines.count > previewLines.count {
            preview += "\n\n…（已折叠，点击展开查看完整内容）"
        }

        return preview
    }

    /// 当前应显示的内容（折叠时截断，展开时完整）
    private var displayContent: String {
        if shouldCollapse && !isExpanded {
            return collapsedContent
        }
        return content
    }

    /// 是否需要分段渲染（超长文本按段落分割，避免单条 Text O(n²) 布局）
    private var shouldSegment: Bool {
        displayContent.count > segmentCharThreshold
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.baizeAccent)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                // 内容渲染：分段或单条 Text
                if shouldSegment {
                    segmentedContentBubble
                } else {
                    Text(displayContent)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        // Bug 6 fix: 确保长文本垂直扩展、水平不溢出
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.baizeBubbleAssistant)
                        .cornerRadius(12)
                }

                // 展开/折叠按钮（仅当消息超过阈值时显示）
                if shouldCollapse {
                    Button(action: toggleExpansion) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                            Text(isExpanded ? "收起" : "展开全文")
                                .font(.caption)
                        }
                        .foregroundColor(.baizeAccent)
                    }
                    .buttonStyle(.plain)
                }

                Text(timestamp.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer(minLength: 40)
        }
    }

    /// 分段渲染视图 — 超长文本按段落（\n\n）分割，每段一个 Text
    /// 避免 SwiftUI Text 超长字符串 O(n²) 布局（验收标准 #1/#2/#7）
    /// 不破坏 Markdown 代码块渲染：代码块本身就是 \n\n 分隔的段落
    private var segmentedContentBubble: some View {
        let paragraphs = displayContent.components(separatedBy: "\n\n")

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeBubbleAssistant)
        .cornerRadius(12)
    }
}

// MARK: - Tool Call Bubble

/// 工具调用气泡 — 显示工具名 + 参数摘要 + 执行状态
/// B13 fix: 工具调用结果默认折叠，点击展开查看完整内容
private struct ToolCallBubble: View {
    let toolCall: ToolCall
    /// W12 fix: 使用 ToolCallView.ToolCallStatus（唯一定义）而非 DisplayMessage.ToolCallStatus
    let status: ToolCallView.ToolCallStatus
    let result: ToolResult?
    let denialReason: String?

    // B13 fix: 工具调用结果默认折叠
    @State private var isResultExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 工具调用标题
            HStack(spacing: 8) {
                // 状态图标
                statusIcon

                // 工具名 + 参数摘要
                VStack(alignment: .leading, spacing: 2) {
                    Text("🔧 \(toolCall.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.baizeAccent)

                    Text(argumentSummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(toolCallBackground)
            .cornerRadius(10)

            // 执行结果（如果已完成）— B13 fix: 默认折叠，点击展开
            if let result = result, status == .completed {
                ResultBubble(result: result, isExpanded: $isResultExpanded)
            }

            // 拒绝原因（如果被拒绝）
            if let reason = denialReason, status == .denied {
                DenialBubble(reason: reason)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
        case .executing:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 14))
        }
    }

    private var toolCallBackground: Color {
        switch status {
        case .pending: return Color.baizeToolCallBackground.opacity(0.5)
        case .executing: return Color.baizeToolCallBackground
        case .completed: return Color.baizeToolResultBackground
        case .denied: return Color.red.opacity(0.1)
        }
    }

    /// 工具参数摘要（B12 fix: 统一截断到 120 字符，避免部分全显部分省略的不一致）
    private var argumentSummary: String {
        let args = toolCall.parsedArguments()
        if args.isEmpty {
            // P0-5 fix: parsedArguments 为空时显示原始参数
            if !toolCall.arguments.isEmpty && toolCall.arguments != "{}" {
                return toolCall.arguments.truncated(to: 120)
            }
            return "无参数"
        }
        // 显示最重要的参数值
        let mainArgs = args.map { "\(String($0.key).prefix(20)): \(String(describing: $0.value).prefix(40))" }
        return mainArgs.joined(separator: ", ").truncated(to: 120)
    }
}

// MARK: - Result Bubble

/// 工具执行结果气泡
/// B12 fix: 使用 ScrollView + 统一截断阈值（2000 字符），避免部分全显部分省略
/// B13 fix: 默认折叠，点击展开查看完整内容
private struct ResultBubble: View {
    let result: ToolResult
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(result.isError ? "⚠️ 执行错误" : "✅ 执行结果")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(result.isError ? .red : .green)

                Spacer()

                // B13 fix: 展开/折叠按钮
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                        Text(isExpanded ? "收起" : "展开")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                // B12 fix: 展开时使用 ScrollView 显示完整内容（最多 2000 字符）
                ScrollView(.vertical, showsIndicators: true) {
                    Text(result.output.truncated(to: 2000))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            } else {
                // 折叠时显示前 2 行预览
                Text(result.output.truncated(to: 200))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(result.isError ? Color.red.opacity(0.05) : Color.green.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Denial Bubble

/// 权限拒绝气泡
private struct DenialBubble: View {
    let reason: String

    var body: some View {
        Text("❌ 拒绝: \(reason)")
            .font(.system(size: 12))
            .foregroundColor(.red.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)
    }
}

// MARK: - Error Message Bubble

/// 错误消息气泡 — 红色警示样式
private struct ErrorMessageBubble: View {
    let content: String
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 14))

            Text(content)
                .font(.system(size: 14))
                .foregroundColor(.red.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(12)

            Spacer()
        }
    }
}

// MARK: - System Message Bubble (P0-2: 压缩提示)

/// 系统消息气泡 — 居中灰色卡片，用于压缩提示等系统级消息
/// 区别于 user（右对齐）/ assistant（左对齐）消息
private struct SystemMessageBubble: View {
    let content: String

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Text(content)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "1C1C1E"))
            .cornerRadius(10)
            Spacer()
        }
    }
}