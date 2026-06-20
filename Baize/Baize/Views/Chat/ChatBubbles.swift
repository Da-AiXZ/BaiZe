import SwiftUI

// MARK: - Chat Header

/// 对话面板标题栏 — 显示 Agent 运行状态
/// 配色适配 DeepSeek 蓝白（.purple → baizeAccent）
struct ChatHeader: View {
    @ObservedObject var appState: AppState
    let isStreaming: Bool
    let onShowSessionList: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // P1-1: 会话列表按钮（左侧）
            Button(action: onShowSessionList) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 16))
                    .foregroundColor(.baizeTextSecondary)
            }
            .buttonStyle(.plain)

            Text("对话")
                .font(.headline)

            if isStreaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Agent 正在思考...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Phase 2C: 模型指示器（baizeAccent 配色）
            Text("\(appState.activeProvider.displayName) / \(appState.activeModel)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.baizeAccent.opacity(0.1))
                .cornerRadius(4)

            Text(appState.permissionMode.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.baizeAccent.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground)
    }
}

// MARK: - Streaming Text Bubble

/// 流式文本气泡 — Agent 正在输出时使用
struct StreamingTextBubble: View {
    let text: String

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
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    // Bug 6 fix: 确保长文本垂直扩展、水平不溢出
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.baizeBubbleAssistant)
                    .cornerRadius(12)

                Text("正在输出...")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer(minLength: 40)
        }
    }
}

// MARK: - Context Usage Bar (P2-5)

/// 上下文用量指示器 — 显示当前 token 用量 / contextWindow + 颜色分级 + 进度条
/// 颜色分级：
///   - hasCompacted = true → 绿色（已压缩，历史被摘要）
///   - ratio >= 0.7 → 橙色（接近阈值，即将触发压缩）
///   - 正常 → 灰色
struct ContextUsageBar: View {
    let tokens: Int
    let window: Int
    let hasCompacted: Bool

    /// 用量比例 (0.0 ~ 1.0)
    private var ratio: Double {
        guard window > 0 else { return 0 }
        return Double(tokens) / Double(window)
    }

    /// 格式化 token 数为可读字符串
    /// 低于 1K 时显示原始数字，高于 1K 时显示 1 位小数 K，高于 1M 时显示 M
    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        } else if value >= 1000 {
            return String(format: "%.1fK", Double(value) / 1000.0)
        } else {
            return "\(value)"
        }
    }

    /// 格式化 contextWindow 为可读字符串
    private func formatWindow(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000.0)
        } else if value >= 1000 {
            return String(format: "%.0fK", Double(value) / 1000.0)
        } else {
            return "\(value)"
        }
    }

    /// 颜色分级
    private var barColor: Color {
        if hasCompacted {
            return .baizeSuccess
        } else if ratio >= 0.7 {
            return .baizeWarning
        } else {
            return .baizeTextSecondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // 📦 图标：已压缩时显示
            if hasCompacted {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundColor(.baizeSuccess)
            }

            Text("上下文: \(formatTokens(tokens)) / \(formatWindow(window)) (\(String(format: "%.1f", ratio * 100))%)")
                .font(.caption)
                .foregroundColor(barColor)

            ProgressView(value: Double(tokens), total: Double(max(window, 1)))
                .progressViewStyle(LinearProgressViewStyle(tint: barColor))
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 28)
        .background(Color.baizeCardBackground)
    }
}
