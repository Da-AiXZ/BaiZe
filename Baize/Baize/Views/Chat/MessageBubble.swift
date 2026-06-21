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
    /// 分段渲染阈值：超过 5000 字符的消息按段落分割渲染
    private let segmentCharThreshold: Int = 5000

    /// 是否应折叠（超过阈值）
    private var shouldCollapse: Bool {
        content.count > collapseCharThreshold
            || content.components(separatedBy: "\n").count > collapseLineThreshold
    }

    /// 折叠时显示的内容（前 50 行）
    private var collapsedContent: String {
        let lines = content.components(separatedBy: "\n")
        let previewLines = Array(lines.prefix(collapseLineThreshold))
        return previewLines.joined(separator: "\n")
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
private struct ToolCallBubble: View {
    let toolCall: ToolCall
    /// W12 fix: 使用 ToolCallView.ToolCallStatus（唯一定义）而非 DisplayMessage.ToolCallStatus
    let status: ToolCallView.ToolCallStatus
    let result: ToolResult?
    let denialReason: String?

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
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(toolCallBackground)
            .cornerRadius(10)

            // 执行结果（如果已完成）
            if let result = result, status == .completed {
                ResultBubble(result: result)
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

    /// 工具参数摘要（截断到 60 字符）
    private var argumentSummary: String {
        let args = toolCall.parsedArguments()
        if args.isEmpty { return "无参数" }
        // 显示最重要的参数值
        let mainArgs = args.map { "\(String($0.key).prefix(20)): \(String(describing: $0.value).prefix(30))" }
        return mainArgs.joined(separator: ", ").truncated(to: 60)
    }
}

// MARK: - Result Bubble

/// 工具执行结果气泡
private struct ResultBubble: View {
    let result: ToolResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "⚠️ 执行错误" : "✅ 执行结果")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(result.isError ? .red : .green)

            Text(result.output.truncated(to: 500))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(5)
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