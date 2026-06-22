import SwiftUI
import Foundation
import ios_system

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
    /// 估算 Token 数（CJK 区分估算：中日韩字符按 0.6 token/字，其他按 UTF-8 byte × 0.25）
    /// P1-5: 原 utf8.count × 0.25 对中文严重低估（1 个汉字 3 字节 → 0.75 token，
    /// 实际 BPE 分词约 0.6-1.5 token），改用 unicodeScalars 遍历区分
    var estimatedTokens: Int {
        var cjkCount = 0
        var nonCjkByteCount = 0

        for scalar in self.unicodeScalars {
            if Self.isCJK(scalar) {
                cjkCount += 1
            } else {
                nonCjkByteCount += String(scalar).utf8.count
            }
        }

        let cjkTokens = Double(cjkCount) * BaizeToken.cjkTokenRatio
        let nonCjkTokens = Double(nonCjkByteCount) * BaizeToken.nonCjkByteRatio
        return Int(cjkTokens + nonCjkTokens)
    }

    /// 判断 Unicode 标量是否为 CJK（中日韩）字符
    /// 覆盖：CJK 统一表意文字、扩展A、兼容表意、日文假名、韩文音节、全角字符
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)    // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(v)    // CJK 扩展 A
            || (0xF900...0xFAFF).contains(v)    // CJK 兼容表意文字
            || (0x3040...0x30FF).contains(v)    // 日文假名（平假名+片假名）
            || (0xAC00...0xD7AF).contains(v)    // 韩文音节
            || (0xFF00...0xFFEF).contains(v)    // 全角字符
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
    /// B01 fix (round 2): 改进目录创建逻辑，四级回退策略
    /// 1. FileManager.createDirectory(withIntermediateDirectories: true) — 标准方式
    /// 2. 逐级创建每个路径组件 — 避免一次性创建多级目录的权限问题
    /// 3. posix_spawn mkdir -p — TrollStore no-sandbox 环境回退
    /// 4. ios_system ios_popen mkdir -p — 终极回退，使用 ios_system 内置 mkdir
    /// B01 fix (round 2): 新增第 4 级回退，使用 ios_system 的 ios_popen 执行 mkdir
    /// 这是 AI 通过 execute_command 成功创建目录的同一套机制（ios_system 内置 mkdir）
    func ensureDirectoryExists(atPath path: String) throws {
        if !fileExists(atPath: path) {
            // 尝试 FileManager 创建（标准方式）
            do {
                try createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                // B01 fix: 回退 1 — 逐级创建路径组件
                baizeLogger.warning("FileManager.createDirectory failed for \(path): \(error.localizedDescription), trying component-by-component creation")
                do {
                    try createDirectoryComponents(atPath: path)
                    if fileExists(atPath: path) {
                        baizeLogger.info("Directory created via component-by-component: \(path)")
                        return
                    }
                } catch {
                    baizeLogger.warning("Component-by-component creation also failed: \(error.localizedDescription), trying posix_spawn fallback")
                }

                // B01 fix: 回退 2 — posix_spawn 执行 mkdir -p
                do {
                    try createDirectoryWithPosixSpawn(atPath: path)
                    if fileExists(atPath: path) {
                        return
                    }
                } catch {
                    baizeLogger.warning("posix_spawn mkdir failed: \(error.localizedDescription), trying ios_system ios_popen fallback")
                }

                // B01 fix (round 2): 回退 3 — ios_system ios_popen 执行 mkdir -p
                // ios_system 内置了 mkdir 命令，不依赖 /bin/mkdir 二进制
                // 这是 AI 通过 execute_command 成功创建目录的同一套机制
                try createDirectoryWithIosSystem(atPath: path)
            }
        }
    }

    /// B01 fix: 逐级创建路径组件
    /// 将路径拆分为各组件，逐个创建，避免 withIntermediateDirectories 在某些环境下失败
    private func createDirectoryComponents(atPath path: String) throws {
        // 标准化路径 — 去掉末尾的 /
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalizedPath.split(separator: "/").map(String.init)

        var currentPath = ""
        for component in components {
            currentPath += "/" + component
            if !fileExists(atPath: currentPath) {
                try createDirectory(atPath: currentPath, withIntermediateDirectories: false)
            }
        }
    }

    /// P0-1 fix: 使用 posix_spawn 执行 mkdir -p 创建目录（TrollStore 回退方案）
    /// TrollStore + no-sandbox 环境下，posix_spawn 创建的子进程可能绕过 FileManager 的沙盒限制
    private func createDirectoryWithPosixSpawn(atPath path: String) throws {
        // 尝试多个 mkdir 路径（iOS 上可能在 /bin/ 或 /usr/bin/）
        let mkdirPaths = ["/bin/mkdir", "/usr/bin/mkdir"]

        var spawnSuccess = false
        var lastError: String = ""

        for mkdirPath in mkdirPaths {
            guard fileExists(atPath: mkdirPath) else { continue }

            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("mkdir"),
                strdup("-p"),
                strdup(path),
                nil
            ]
            defer {
                for ptr in argv { if let p = ptr { free(p) } }
            }

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, mkdirPath, nil, nil, argv, nil)

            if spawnResult != 0 {
                lastError = "posix_spawn failed (errno=\(spawnResult))"
                continue
            }

            // 等待子进程完成
            var status: Int32 = 0
            waitpid(pid, &status, 0)

            if status == 0 {
                spawnSuccess = true
                break
            } else {
                lastError = "mkdir -p exited with status \(status)"
                continue
            }
        }

        if !spawnSuccess {
            // posix_spawn 也失败了 — 如果没有找到 mkdir 二进制，尝试 ios_system
            // 作为最后的手段，直接抛出包含诊断信息的错误
            throw BaizeError.fileSystemError(
                "无法创建目录 \(path): \(lastError)。" +
                "TrollStore 环境下可能需要手动创建目录或检查 entitlements 配置。"
            )
        }

        // 验证目录是否创建成功
        if !fileExists(atPath: path) {
            throw BaizeError.fileSystemError("mkdir -p 执行成功但目录仍不存在: \(path)")
        }

        baizeLogger.info("Directory created via posix_spawn: \(path)")
    }

    /// B01 fix (round 2): 使用 ios_system 的 ios_popen 执行 mkdir -p
    /// ios_system 内置了 70+ Unix 命令（包括 mkdir），不依赖系统二进制
    /// 这是 AI 通过 execute_command → RuntimeExecutor → ios_popen 成功创建目录的同一套机制
    /// 解决 FileManager.default 在 TrollStore 环境下的沙盒残留限制
    private func createDirectoryWithIosSystem(atPath path: String) throws {
        // 构建命令：mkdir -p "path"
        // 使用引号包裹路径，处理包含空格的路径
        let command = "mkdir -p \"\(path)\""

        baizeLogger.info("ensureDirectoryExists: trying ios_popen mkdir: \(command)")

        // ios_popen 是 ios_system 库的进程内命令执行接口
        // 它不 fork 进程，而是在当前进程内执行内置命令
        let fp = ios_popen(command, "r")

        guard let filePtr = fp else {
            throw BaizeError.fileSystemError(
                "无法创建目录 \(path): ios_popen 返回 nil。" +
                "FileManager、posix_spawn 和 ios_system 均失败。"
            )
        }

        // 读取输出（mkdir -p 成功时无输出）
        var buffer = [CChar](repeating: 0, count: 256)
        var output = ""
        while fgets(&buffer, Int32(buffer.count), filePtr) != nil {
            output += String(cString: buffer)
        }
        fclose(filePtr)

        // 验证目录是否创建成功
        if !fileExists(atPath: path) {
            let detail = output.isEmpty ? "(无输出)" : output
            throw BaizeError.fileSystemError(
                "ios_popen mkdir 执行完毕但目录仍不存在: \(path)。输出: \(detail)"
            )
        }

        baizeLogger.info("Directory created via ios_system ios_popen: \(path)")
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
    /// 不询问模式：所有需要确认的操作均自动拒绝（不弹窗），参考 Claude Code dontAsk
    case dontAsk

    var displayName: String {
        switch self {
        case .default: return "默认（每次确认）"
        case .acceptEdits: return "接受编辑"
        case .plan: return "只读规划"
        case .bypass: return "绕过模式"
        case .dontAsk: return "不询问"
        }
    }

    var description: String {
        switch self {
        case .default: return "每次危险操作前需确认"
        case .acceptEdits: return "自动接受文件编辑，执行命令仍需确认"
        case .plan: return "Agent 只分析不执行，禁止所有写入"
        case .bypass: return "自动执行所有操作（需确认开启）"
        case .dontAsk: return "所有需要确认的操作均自动拒绝，不弹出任何权限对话框"
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

// MARK: - Message → DisplayMessage Conversion (P1-1)

/// 将 [Message] 转换为 [DisplayMessage] 供 UI 显示
/// assistantWithToolCalls 展开为多条 DisplayMessage（文本 + 每个工具调用各一条）
/// toolResult 简化为 system 消息显示前 100 字（UI 层已在 toolCall 中展示状态）
extension Array where Element == Message {
    func toDisplayMessages() -> [DisplayMessage] {
        flatMap { msg -> [DisplayMessage] in
            switch msg {
            case .user(let text):
                return [DisplayMessage(role: .user, content: text, timestamp: Date())]

            case .assistant(let text):
                return [DisplayMessage(role: .assistant, content: text, timestamp: Date())]

            case .assistantWithToolCalls(let content, let toolCalls):
                // 展开为多条：先显示文本（如有），再显示每个工具调用
                var results: [DisplayMessage] = []
                if !content.isEmpty {
                    results.append(DisplayMessage(role: .assistant, content: content, timestamp: Date()))
                }
                for call in toolCalls {
                    results.append(DisplayMessage(
                        role: .toolCall,
                        content: "调用 \(call.name)",
                        timestamp: Date(),
                        toolCall: call,
                        toolStatus: .completed
                    ))
                }
                return results

            case .toolResult(let id, let content):
                // 工具结果简化为系统消息（UI 层已在 toolCall 中展示状态）
                let preview = content.count > 100
                    ? "\(content.prefix(100))..."
                    : content
                return [DisplayMessage(
                    role: .system,
                    content: "工具结果: \(preview)",
                    timestamp: Date()
                )]

            case .system(let text):
                return [DisplayMessage(role: .system, content: text, timestamp: Date())]

            case .toolCall(let id, let name, let arguments):
                // 历史兼容：独立 toolCall 消息
                let call = ToolCall(id: id, name: name, arguments: arguments)
                return [DisplayMessage(
                    role: .toolCall,
                    content: "调用 \(name)",
                    timestamp: Date(),
                    toolCall: call,
                    toolStatus: .completed
                )]
            }
        }
    }
}
