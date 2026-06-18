import SwiftUI
import Foundation

// MARK: - Color Extensions (App Theme)

/// 白泽主题色扩展 — DeepSeek 蓝白配色系统
/// 保持变量名不变，仅替换色值为 DeepSeek 风格蓝白极简
extension Color {
    // 主色调 (DeepSeek 蓝白)
    static let baizeAccent = Color(hex: "2563EB")           // 主强调色 (blue-600, DeepSeek 主蓝)
    static let baizePrimary = Color(hex: "2563EB")          // baizeAccent 语义别名
    static let baizePrimaryLight = Color(hex: "3B82F6")     // 选中态高亮 (blue-500)

    // 背景
    static let baizeBackground = Color(hex: "0F172A")       // 全局背景 (slate-900, 深蓝黑)
    static let baizeCardBackground = Color(hex: "1E293B")   // 卡片/面板背景 (slate-800)
    static let baizeEditorBackground = Color(hex: "1E1E1E") // 编辑器背景 (VS Code Dark, 不变)
    static let baizeChatBackground = Color(hex: "0F172A")   // 对话面板背景 (slate-900)

    // 文字
    static let baizeTextPrimary = Color(hex: "F1F5F9")      // 正文 (slate-100, 高对比)
    static let baizeTextSecondary = Color(hex: "94A3B8")    // 次要文字 (slate-400)

    // 边框/分割
    static let baizeBorder = Color(hex: "334155")           // 分割线/边框 (slate-700)

    // 状态色
    static let baizeSuccess = Color(hex: "10B981")          // 成功 (emerald-500)
    static let baizeWarning = Color(hex: "F59E0B")          // 警告 (amber-500)
    static let baizeError = Color(hex: "EF4444")            // 错误 (red-500)

    // Tab 栏
    static let baizeTabBarBackground = Color(hex: "1E293B") // slate-800
    static let baizeTabActive = Color(hex: "334155")        // slate-700

    // Chat 面板
    static let baizeInputBackground = Color(hex: "1E293B")  // slate-800
    static let baizeInputFieldBackground = Color(hex: "334155") // slate-700
    static let baizeInputBorder = Color(hex: "475569")      // slate-600
    static let baizeBubbleAssistant = Color(hex: "1E293B")  // slate-800
    static let baizeToolCallBackground = Color(hex: "1E293B") // slate-800, 蓝白统一
    static let baizeToolResultBackground = Color(hex: "064E3B") // emerald-900

    // 文件浏览器
    static let baizeFolder = Color(hex: "FBBF24")           // amber-400

    /// 从十六进制字符串创建 Color
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: // RGB (no alpha)
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // ARGB
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - String Extensions

extension String {
    /// 估算 Token 数（简单启发式：字符数 × 0.25）
    var estimatedTokens: Int {
        Int(Double(utf8.count) * BaizeToken.tokenEstimateMultiplier)
    }

    /// 截断到最大长度，超过时添加截断提示
    func truncated(to maxLength: Int) -> String {
        if utf8.count <= maxLength { return self }
        let truncated = String(self.prefix(maxLength))
        let notice = BaizeRuntime.truncationNotice.replacingOccurrences(
            of: "{total}",
            with: "\(utf8.count)"
        )
        return truncated + notice
    }

    /// 从文件路径提取扩展名
    var fileExtension: String {
        (self as NSString).pathExtension
    }

    /// 从文件路径提取文件名
    var fileName: String {
        URL(fileURLWithPath: self).lastPathComponent
    }

    /// 从文件路径提取目录路径
    var directoryPath: String {
        (self as NSString).deletingLastPathComponent
    }

    /// 判断是否为 BAIZE.md 配置文件
    var isBaizeConfig: Bool {
        fileName == BaizePath.projectConfigFile
    }
}

// MARK: - Date Extensions

extension Date {
    /// 格式化为对话时间戳显示
    var chatTimestamp: String {
        formatted(.relative(presentation: .named))
    }

    /// 格式化为文件修改时间
    var fileModifiedTime: String {
        formatted(.dateTime.year().month().day().hour().minute())
    }
}

// MARK: - URL Extensions

extension URL {
    /// 判断 URL 是否指向项目内的 BAIZE.md
    var isBaizeConfigFile: Bool {
        lastPathComponent == BaizePath.projectConfigFile
    }
}

// MARK: - FileManager Extensions

extension FileManager {
    /// 确保目录存在，不存在则创建
    func ensureDirectoryExists(atPath path: String) throws {
        if !fileExists(atPath: path) {
            try createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    /// 获取文件大小（字节）
    func fileSize(atPath path: String) -> Int64? {
        guard let attrs = try? attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    /// 获取文件修改时间
    func fileModifiedDate(atPath path: String) -> Date? {
        guard let attrs = try? attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return nil
        }
        return date
    }
}

// MARK: - PermissionMode

/// 权限模式枚举 — 定义 Agent 操作的确认策略
/// default: 每次危险操作确认
/// acceptEdits: 自动接受文件编辑
/// plan: 只读规划（禁止所有写入）
/// bypass: 自动执行所有操作，需用户明确确认开启
enum PermissionMode: String, CaseIterable, Codable {
    case `default`
    case acceptEdits
    case plan
    case bypass

    var displayName: String {
        switch self {
        case .default: return "默认（每次确认）"
        case .acceptEdits: return "接受编辑"
        case .plan: return "只读规划"
        case .bypass: return "绕过模式"
        }
    }

    var description: String {
        switch self {
        case .default: return "每次危险操作前需确认"
        case .acceptEdits: return "自动接受文件编辑，执行命令仍需确认"
        case .plan: return "Agent 只分析不执行，禁止所有写入"
        case .bypass: return "自动执行所有操作（需确认开启）"
        }
    }
}

// MARK: - Effect (Permission Decision Result)

/// 权限决策效果 — 三态
/// W4 fix: 添加 Sendable，PermissionDecision 跨 actor 隔离边界传递需符合 Sendable
enum Effect: String, Codable, Sendable {
    case allow
    case ask
    case deny
}
