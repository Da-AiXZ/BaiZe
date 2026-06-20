import Foundation
import SwiftUI

// MARK: - Terminal Data Models

/// 终端行类型 — 决定输出区文本的颜色和样式
enum LineType {
    /// 命令行（用户/Agent 输入的命令，前缀 "$ "）
    case command
    /// 正常 stdout 输出
    case output
    /// stderr / 错误输出（exitCode ≠ 0）
    case error
    /// 系统消息（cd 成功提示、清屏提示、中断提示等）
    case system
}

/// 命令来源 — 区分用户手动输入和 Agent 调用 execute_command 工具
/// 必须 Sendable：AgentEvent 是 @unchecked Sendable，跨 actor 传递时
/// CommandSource 作为关联值需要线程安全
enum CommandSource: Sendable {
    /// 用户手动输入 — 仅显示在终端，不进入对话上下文，不消耗 LLM Token
    case user
    /// Agent 调用 execute_command — 同时显示在终端和对话面板（ToolCallView 摘要）
    case agent
}

/// 终端输出行模型 — 每行输出/命令/错误/系统消息统一用此结构表示
/// Identifiable 用于 ForEach + LazyVStack 高效渲染
struct TerminalLine: Identifiable {
    /// 唯一标识（用于 SwiftUI ForEach + ScrollViewReader 滚动定位）
    let id = UUID()
    /// 行内容（命令行含 "$ " 前缀，输出为原始文本）
    let content: String
    /// 行类型 — 决定颜色和样式
    let type: LineType
    /// 命令来源 — 决定是否显示 [Agent] 标签
    let source: CommandSource
    /// 时间戳
    let timestamp: Date

    /// 默认初始化器
    /// - Parameters:
    ///   - content: 行内容
    ///   - type: 行类型
    ///   - source: 命令来源（默认 .user）
    ///   - timestamp: 时间戳（默认当前时间）
    init(content: String, type: LineType, source: CommandSource = .user, timestamp: Date = Date()) {
        self.content = content
        self.type = type
        self.source = source
        self.timestamp = timestamp
    }
}

// MARK: - ANSI Color Parser (T04)

/// ANSI 转义码解析器 — 解析 `\033[...m` 转义序列并映射到 SwiftUI 颜色
/// 支持基本颜色码：
///   - 0: 重置所有样式
///   - 1: 粗体
///   - 30-37: 前景色（黑/红/绿/黄/蓝/品红/青/白）
///   - 40-47: 背景色（同上，P0 暂不渲染背景色，仅解析跳过）
///   - 90-97: 亮色前景色（部分终端扩展）
/// 不支持的码将被安全跳过，不影响文本渲染
enum ANSIParser {

    /// ANSI 颜色码到 SwiftUI Color 的映射（暗色主题适配）
    /// 30-37 标准色 + 90-97 亮色
    private static func color(forCode code: Int) -> Color? {
        switch code {
        case 30:  return Color(hex: "4A4A4A")   // 黑（暗色主题下调亮）
        case 31:  return Color(hex: "EF4444")   // 红
        case 32:  return Color(hex: "10B981")   // 绿
        case 33:  return Color(hex: "F59E0B")   // 黄
        case 34:  return Color(hex: "3B82F6")   // 蓝
        case 35:  return Color(hex: "EC4899")   // 品红
        case 36:  return Color(hex: "06B6D4")   // 青
        case 37:  return Color(hex: "E5E7EB")   // 白（暗色主题下调亮）
        case 90:  return Color(hex: "6B7280")   // 亮黑（灰）
        case 91:  return Color(hex: "F87171")   // 亮红
        case 92:  return Color(hex: "34D399")   // 亮绿
        case 93:  return Color(hex: "FBBF24")   // 亮黄
        case 94:  return Color(hex: "60A5FA")   // 亮蓝
        case 95:  return Color(hex: "F472B6")   // 亮品红
        case 96:  return Color(hex: "22D3EE")   // 亮青
        case 97:  return Color(hex: "F9FAFB")   // 亮白
        default:  return nil                     // 非颜色码（0/1/40-47 等）
        }
    }

    /// 解析含 ANSI 转义码的文本，返回带颜色的 AttributedString
    /// - Parameter text: 原始文本（可能含 `\033[...m` 转义码）
    /// - Returns: 解析后的 AttributedString，转义码已移除，文本带颜色属性
    static func parse(_ text: String) -> AttributedString {
        var result = AttributedString()
        var currentColor: Color? = nil
        var currentBold: Bool = false

        // ANSI 转义序列正则：\033[ 或 \x1B[ 开头，以 m 结尾，中间为分号分隔的数字
        // 兼容 ESC 字符 (\u{001B}) 和字面量 \033 表示
        let pattern = "\\u{001B}\\[([0-9;]*)m"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return AttributedString(text)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var lastEnd = 0

        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match = match else { return }

            // 添加匹配前的普通文本
            let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if beforeRange.length > 0 {
                let plainText = nsText.substring(with: beforeRange)
                var segment = AttributedString(plainText)
                if let color = currentColor {
                    segment.foregroundColor = color
                }
                if currentBold {
                    segment.font = .system(.body, design: .monospaced).bold()
                }
                result += segment
            }

            // 解析转义码参数
            let codeStr = nsText.substring(with: match.range(at: 1))
            let codes = codeStr.split(separator: ";").compactMap { Int($0) }

            if codes.isEmpty {
                // 空参数（\033[m）等同于重置
                currentColor = nil
                currentBold = false
            } else {
                for code in codes {
                    switch code {
                    case 0:
                        currentColor = nil
                        currentBold = false
                    case 1:
                        currentBold = true
                    case 30...37, 90...97:
                        currentColor = color(forCode: code)
                    case 40...47, 100...107:
                        // 背景色 — P0 暂不渲染，安全跳过
                        break
                    default:
                        // 其他码（如下划线 4、反色 7 等）— 安全跳过
                        break
                    }
                }
            }

            lastEnd = match.range.location + match.range.length
        }

        // 添加最后一段普通文本
        if lastEnd < nsText.length {
            let remainingText = nsText.substring(from: lastEnd)
            var segment = AttributedString(remainingText)
            if let color = currentColor {
                segment.foregroundColor = color
            }
            if currentBold {
                segment.font = .system(.body, design: .monospaced).bold()
            }
            result += segment
        }

        return result
    }
}
