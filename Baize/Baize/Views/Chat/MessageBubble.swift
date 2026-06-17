import SwiftUI

/// 消息气泡视图 — 区分文本消息、工具调用、工具结果、错误消息
/// 文本消息：用户（蓝色右对齐）/ Agent（灰色左对齐）
/// 工具调用：显示工具名 + 参数摘要 + 执行状态（pending/executing/completed/denied）
/// 错误消息：红色警示样式
struct MessageBubble: View {
    let message: DisplayMessage

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(content: message.content, timestamp: message.timestamp)
        case .assistant:
            AssistantMessageBubble(content: message.content, timestamp: message.timestamp)
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
private struct AssistantMessageBubble: View {
    let content: String
    let timestamp: Date

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
                Text(content)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.baizeBubbleAssistant)
                    .cornerRadius(12)

                Text(timestamp.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer(minLength: 40)
        }
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