import SwiftUI

/// 工具调用状态可视化视图 — 显示工具执行过程的详细状态
/// 独立组件，也可在 MessageBubble 内嵌使用
/// 支持 4 种状态：pending（等待）/ executing（执行中）/ completed（完成）/ denied（拒绝）
/// W12 fix: ToolCallStatus 定义在此处为唯一来源，其他文件引用此类型而非重复定义
struct ToolCallView: View {
    let toolCall: ToolCall
    let status: ToolCallView.ToolCallStatus
    let result: ToolResult?
    let denialReason: String?

    /// 工具调用状态 — W12 fix: 从 DisplayMessage 移至此处作为唯一定义
    enum ToolCallStatus: Sendable {
        case pending
        case executing
        case completed
        case denied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 状态头部
            HStack(spacing: 10) {
                statusIndicator
                toolNameLabel
                Spacer()
                statusBadge
            }

            // 参数详情
            ArgumentsPreview(arguments: toolCall.parsedArguments())

            // 执行结果（展开显示）
            if let result = result {
                ResultPreview(result: result)
            }

            // 拒绝原因
            if let reason = denialReason {
                DenialPreview(reason: reason)
            }
        }
        .padding(12)
        .background(containerBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        switch status {
        case .pending:
            return AnyView(
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
            )
        case .executing:
            return AnyView(
                ProgressView()
                    .scaleEffect(0.8)
            )
        case .completed:
            return AnyView(
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            )
        case .denied:
            return AnyView(
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 16))
            )
        }
    }

    // MARK: - Tool Name Label

    private var toolNameLabel: some View {
        HStack(spacing: 4) {
            Text(toolCallIcon)
                .font(.system(size: 14))

            Text(toolCall.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.baizeAccent)
        }
    }

    /// 工具名对应的图标
    private var toolCallIcon: String {
        switch toolCall.name {
        case "read_file": return "📄"
        case "write_file": return "📝"
        case "edit_file": return "✏️"
        case "list_directory": return "📁"
        case "search_files": return "🔍"
        case "search_content": return "🔎"
        case "execute_command": return "⌨️"
        case "run_node": return "🟢"
        case "run_python": return "🐍"
        default: return "🔧"
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2)
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .cornerRadius(4)
    }

    private var statusText: String {
        switch status {
        case .pending: return "等待"
        case .executing: return "执行中"
        case .completed: return "完成"
        case .denied: return "拒绝"
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending: return .secondary
        case .executing: return .orange
        case .completed: return .green
        case .denied: return .red
        }
    }

    // MARK: - Background/Border

    private var containerBackground: Color {
        switch status {
        case .pending: return Color.baizeCardBackground.opacity(0.5)
        case .executing: return Color.baizeToolCallBackground
        case .completed: return Color.baizeToolResultBackground
        case .denied: return Color.red.opacity(0.05)
        }
    }

    private var borderColor: Color {
        switch status {
        case .pending: return .secondary.opacity(0.2)
        case .executing: return Color.baizeAccent.opacity(0.3)
        case .completed: return .green.opacity(0.3)
        case .denied: return .red.opacity(0.3)
        }
    }
}

// MARK: - Arguments Preview

/// 工具参数预览
private struct ArgumentsPreview: View {
    let arguments: [String: Any]

    var body: some View {
        if !arguments.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(arguments.keys.sorted()), id: \.self) { key in
                    HStack(spacing: 4) {
                        Text(key + ":")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(String(describing: arguments[key]!).truncated(to: 80))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Result Preview

/// 工具执行结果预览
private struct ResultPreview: View {
    let result: ToolResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            Text(result.isError ? "⚠️ 错误输出:" : "✅ 输出:")
                .font(.system(size: 12, weight: .medium))

            Text(result.output.truncated(to: 300))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary.opacity(0.7))
                .lineLimit(8)
        }
    }
}

// MARK: - Denial Preview

/// 权限拒绝详情
private struct DenialPreview: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("❌ 拒绝原因: \(reason)")
                .font(.system(size: 12))
                .foregroundColor(.red.opacity(0.8))
        }
    }
}