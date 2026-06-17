import SwiftUI

/// 权限确认弹窗 — Agent 请求用户确认危险操作时显示
/// 显示：工具名、操作描述、目标路径/命令
/// 提供 Allow / Deny 按钮 + "本次会话不再询问"选项
/// 内嵌在 ChatView 中使用（而非独立 sheet）
struct PermissionDialog: View {
    let toolCall: ToolCall
    let reason: String
    let onAllow: () -> Void
    let onDeny: () -> Void

    @State private var skipForSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 18))
                Text("权限确认")
                    .font(.headline)
            }

            // 操作描述
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent 请求执行以下操作:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // 工具名
                HStack(spacing: 6) {
                    Text("工具:")
                        .font(.system(size: 13, weight: .medium))
                    Text(toolCall.name)
                        .font(.system(size: 13))
                        .foregroundColor(Color.baizeAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.baizeAccent.opacity(0.1))
                        .cornerRadius(4)
                }

                // 操作原因
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(8)
            }

            // 参数详情
            if !toolCall.arguments.isEmpty {
                ArgumentsDetail(arguments: toolCall.parsedArguments())
            }

            // "本次会话不再询问"选项
            if toolCall.name != "execute_command" {
                Toggle("本次会话不再询问此操作", isOn: $skipForSession)
                    .font(.system(size: 13))
                    .toggleStyle(.switch)
            }

            // 操作按钮
            HStack(spacing: 12) {
                // Deny 按钮
                Button(role: .cancel, action: onDeny) {
                    Label("拒绝", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                // Allow 按钮
                Button(action: onAllow) {
                    Label("允许", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.baizeAccent)
            }
        }
        .padding(16)
        .background(Color.baizeBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 2)
        )
        .padding(.horizontal, 12)
    }
}

// MARK: - Arguments Detail

/// 工具调用参数详情展示
private struct ArgumentsDetail: View {
    let arguments: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("参数详情:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            ForEach(Array(arguments.keys.sorted()), id: \.self) { key in
                HStack(spacing: 4) {
                    Text(key)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("=")
                        .foregroundColor(.secondary)
                    Text(String(describing: arguments[key]!).truncated(to: 100))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }
}