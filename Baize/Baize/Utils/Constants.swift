import Foundation

/// 白泽全局常量定义
/// 包含文件路径、API 配置、Token 预算、超时设置等

// MARK: - File Paths

/// 白泽核心路径常量
enum BaizePath {
    /// 用户项目根目录（TrollStore no-sandbox 环境下可访问）
    static let projectRoot = "/var/mobile/Documents/Baize/"

    /// 白泽内部数据目录
    static let internalData = "/var/mobile/Documents/Baize/.baize/"

    /// 对话持久化目录
    static let conversations = "/var/mobile/Documents/Baize/.baize/conversations/"

    /// 全局配置文件
    static let globalConfig = "/var/mobile/Documents/Baize/.baize/config.json"

    /// BAIZE.md 项目配置文件名
    static let projectConfigFile = "BAIZE.md"

    /// App Bundle 内 Node.js 二进制路径
    static let nodeBinary = "Frameworks/node"

    /// App Bundle 内 Python 二进制路径
    static let pythonBinary = "Frameworks/python3"

    /// App Bundle 内 Monaco Editor 资源目录
    static let monacoResources = "monaco-editor"
}

// MARK: - API Configuration

/// API 相关常量
enum BaizeAPI {
    /// OpenAI Chat Completions 端点
    static let openAIEndpoint = "https://api.openai.com/v1/chat/completions"

    /// 默认模型（Phase 1 仅支持 gpt-4o）
    static let defaultModel = "gpt-4o"

    /// API Key Keychain 存储键名
    static let openAIKeyKeychainKey = "com.baize.openai-api-key"

    /// Anthropic API Key Keychain 存储键名
    static let anthropicKeyKeychainKey = "com.baize.anthropic-api-key"

    /// OpenRouter API Key Keychain 存储键名
    static let openRouterKeyKeychainKey = "com.baize.openrouter-api-key"

    /// SSE 流式请求超时（秒）
    static let streamTimeout: TimeInterval = 120.0

    /// 非流式请求超时（秒）
    static let requestTimeout: TimeInterval = 30.0

    /// 网络错误自动重试次数
    static let maxRetries = 1
}

// MARK: - Token Budget

/// Token 预算管理常量
enum BaizeToken {
    /// 最大上下文 Token 数（gpt-4o 128K 上下文）
    static let maxContextTokens = 128_000

    /// 系统提示预留 Token
    static let systemPromptReserve = 4_000

    /// 工具定义预留 Token
    static let toolDefinitionsReserve = 2_000

    /// 可用对话历史 Token（= maxContext - systemPrompt - toolDefinitions）
    static let availableHistoryTokens = maxContextTokens - systemPromptReserve - toolDefinitionsReserve

    /// 压缩触发阈值（超过此比例时执行 Snip 压缩）
    static let compactThresholdRatio = 0.8

    /// 单次估算 Token 乘数（字符数 × 此系数 ≈ Token 数）
    static let tokenEstimateMultiplier = 0.25
}

// MARK: - Runtime Configuration

/// 运行时执行配置
enum BaizeRuntime {
    /// Shell 命令执行超时（秒）
    static let commandTimeout: TimeInterval = 30.0

    /// Node.js 脚本执行超时（秒）
    static let nodeTimeout: TimeInterval = 30.0

    /// Python 脚本执行超时（秒）
    static let pythonTimeout: TimeInterval = 30.0

    /// 临时脚本目录
    static let tempScriptDir = "/tmp/baize-scripts/"

    /// 工具执行结果最大长度（超过截断）
    static let maxResultSize = 10_000

    /// 工具执行结果截断提示
    static let truncationNotice = "\n... (结果已截断，共 {total} 字符)"
}

// MARK: - Permission Defaults

/// 权限引擎默认配置
enum BaizePermission {
    /// 默认权限模式
    static let defaultMode = PermissionMode.default

    /// 始终拒绝的操作（不可通过权限模式绕过）
    static let alwaysDenyPatterns: Set<String> = [
        "rm -rf /",
        "rm -rf /var",
        "rm -rf /System",
        "mkfs",
        "dd if=/dev/zero",
    ]

    /// 始终需确认的危险操作关键词
    static let dangerousKeywords: Set<String> = [
        "rm", "rmdir", "delete", "remove",
        "chmod 000", "chown root",
    ]
}

// MARK: - BaizeError

/// 白泽统一错误类型 — 所有 async throws 函数使用此类型
enum BaizeError: LocalizedError {
    case apiError(String)
    case sseParseError(String)
    case fileSystemError(String)
    case toolExecutionError(String)
    case spawnError(Int32)
    case permissionDenied(String)
    case apiKeyMissing
    case runtimeNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "API 错误: \(msg)"
        case .sseParseError(let msg): return "SSE 解析错误: \(msg)"
        case .fileSystemError(let msg): return "文件系统错误: \(msg)"
        case .toolExecutionError(let msg): return "工具执行错误: \(msg)"
        case .spawnError(let code): return "进程启动失败 (code: \(code))"
        case .permissionDenied(let msg): return "权限被拒绝: \(msg)"
        case .apiKeyMissing: return "API Key 未配置，请在设置中添加"
        case .runtimeNotAvailable(let name): return "运行时 \(name) 不可用"
        }
    }
}