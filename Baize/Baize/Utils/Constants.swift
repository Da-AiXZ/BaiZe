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

    /// Anthropic Messages 端点
    static let anthropicEndpoint = "https://api.anthropic.com/v1/messages"

    /// OpenRouter Chat Completions 端点
    static let openRouterEndpoint = "https://openrouter.ai/api/v1/chat/completions"

    /// Anthropic API 版本号
    static let anthropicVersion = "2023-06-01"

    /// 默认模型
    static let defaultModel = "gpt-4.1"

    /// API Key Keychain 存储键名
    static let openAIKeyKeychainKey = "com.baize.openai-api-key"

    /// Anthropic API Key Keychain 存储键名
    static let anthropicKeyKeychainKey = "com.baize.anthropic-api-key"

    /// OpenRouter API Key Keychain 存储键名
    static let openRouterKeyKeychainKey = "com.baize.openrouter-api-key"

    /// DeepSeek 官方 API 端点（OpenAI 兼容格式）
    static let deepSeekEndpoint = "https://api.deepseek.com/v1/chat/completions"

    /// 自定义 Provider API Key Keychain 存储键名
    static let customProviderKeyKeychainKey = "com.baize.custom-api-key"

    /// UserDefaults: 自定义端点 URL
    static let customEndpointUDKey = "com.baize.custom-endpoint"

    /// UserDefaults: 自定义模型名
    static let customModelUDKey = "com.baize.custom-model"

    /// SSE 流式请求超时（秒）
    static let streamTimeout: TimeInterval = 120.0

    /// 非流式请求超时（秒）
    static let requestTimeout: TimeInterval = 30.0

    /// 网络错误自动重试次数
    static let maxRetries = 1
}

// MARK: - Model Definitions

/// 各 Provider 推荐模型列表
enum BaizeModels {
    // MARK: OpenAI Models

    /// OpenAI 推荐模型
    enum OpenAI {
        static let gpt41 = ModelInfo(
            id: "gpt-4.1",
            displayName: "GPT-4.1",
            provider: "openai",
            contextWindow: 1_000_000
        )
        static let gpt41Mini = ModelInfo(
            id: "gpt-4.1-mini",
            displayName: "GPT-4.1 Mini",
            provider: "openai",
            contextWindow: 1_000_000
        )
        static let gpt41Nano = ModelInfo(
            id: "gpt-4.1-nano",
            displayName: "GPT-4.1 Nano",
            provider: "openai",
            contextWindow: 1_000_000
        )
        static let o3 = ModelInfo(
            id: "o3",
            displayName: "O3",
            provider: "openai",
            contextWindow: 200_000
        )
        static let o4Mini = ModelInfo(
            id: "o4-mini",
            displayName: "O4 Mini",
            provider: "openai",
            contextWindow: 200_000
        )
        static let gpt4o = ModelInfo(
            id: "gpt-4o",
            displayName: "GPT-4o",
            provider: "openai",
            contextWindow: 128_000
        )

        /// 所有可用模型
        static let allModels: [ModelInfo] = [gpt41, gpt41Mini, o4Mini, o3, gpt4o, gpt41Nano]
    }

    // MARK: Anthropic Models

    /// Anthropic 推荐模型
    enum Anthropic {
        static let claudeSonnet4 = ModelInfo(
            id: "claude-sonnet-4-20250514",
            displayName: "Claude Sonnet 4",
            provider: "anthropic",
            contextWindow: 200_000
        )
        static let claudeOpus4 = ModelInfo(
            id: "claude-opus-4-20250514",
            displayName: "Claude Opus 4",
            provider: "anthropic",
            contextWindow: 200_000
        )
        static let claudeHaiku4 = ModelInfo(
            id: "claude-haiku-4-20250414",
            displayName: "Claude Haiku 4",
            provider: "anthropic",
            contextWindow: 200_000
        )

        /// 所有可用模型
        static let allModels: [ModelInfo] = [claudeSonnet4, claudeOpus4, claudeHaiku4]
    }

    // MARK: OpenRouter Models

    /// OpenRouter 推荐模型
    enum OpenRouter {
        static let deepseekV31 = ModelInfo(
            id: "deepseek/deepseek-chat-v3.1",
            displayName: "DeepSeek V3.1",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let deepseekR1_0528 = ModelInfo(
            id: "deepseek/deepseek-r1-0528",
            displayName: "DeepSeek R1 (0528)",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let gpt41 = ModelInfo(
            id: "openai/gpt-4.1",
            displayName: "GPT-4.1 (OpenRouter)",
            provider: "openrouter",
            contextWindow: 1_000_000
        )
        static let claudeOpus4 = ModelInfo(
            id: "anthropic/claude-opus-4-20250514",
            displayName: "Claude Opus 4 (OpenRouter)",
            provider: "openrouter",
            contextWindow: 200_000
        )
        static let o4Mini = ModelInfo(
            id: "openai/o4-mini",
            displayName: "O4 Mini (OpenRouter)",
            provider: "openrouter",
            contextWindow: 200_000
        )
        static let qwen3_32b_instruct = ModelInfo(
            id: "qwen/qwen3-32b-instruct",
            displayName: "Qwen3 32B Instruct",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let deepseekChat = ModelInfo(
            id: "deepseek/deepseek-chat",
            displayName: "DeepSeek V3",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let gemini25Flash = ModelInfo(
            id: "google/gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            provider: "openrouter",
            contextWindow: 1_000_000
        )
        static let gemini25Pro = ModelInfo(
            id: "google/gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            provider: "openrouter",
            contextWindow: 1_000_000
        )
        static let llama4Maverick = ModelInfo(
            id: "meta-llama/llama-4-maverick",
            displayName: "Llama 4 Maverick",
            provider: "openrouter",
            contextWindow: 1_000_000
        )
        static let mistralLarge = ModelInfo(
            id: "mistralai/mistral-large-2411",
            displayName: "Mistral Large",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let claudeSonnet4 = ModelInfo(
            id: "anthropic/claude-sonnet-4-20250514",
            displayName: "Claude Sonnet 4 (OpenRouter)",
            provider: "openrouter",
            contextWindow: 200_000
        )
        static let gpt4o = ModelInfo(
            id: "openai/gpt-4o",
            displayName: "GPT-4o (OpenRouter)",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let qwen3_235b = ModelInfo(
            id: "qwen/qwen3-235b-a22b",
            displayName: "Qwen3 235B",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let deepseekR1 = ModelInfo(
            id: "deepseek/deepseek-r1",
            displayName: "DeepSeek R1",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let claudeHaiku4 = ModelInfo(
            id: "anthropic/claude-haiku-4-20250414",
            displayName: "Claude Haiku 4 (OpenRouter)",
            provider: "openrouter",
            contextWindow: 200_000
        )
        static let gpt4oMini = ModelInfo(
            id: "openai/gpt-4o-mini",
            displayName: "GPT-4o Mini (OpenRouter)",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let llama4Scout = ModelInfo(
            id: "meta-llama/llama-4-scout",
            displayName: "Llama 4 Scout",
            provider: "openrouter",
            contextWindow: 10_000_000
        )
        static let gemini25FlashLite = ModelInfo(
            id: "google/gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            provider: "openrouter",
            contextWindow: 1_000_000
        )
        static let mistralSmall = ModelInfo(
            id: "mistralai/mistral-small-24b-instruct-2501",
            displayName: "Mistral Small 24B",
            provider: "openrouter",
            contextWindow: 128_000
        )
        static let qwen3_32b = ModelInfo(
            id: "qwen/qwen3-32b",
            displayName: "Qwen3 32B",
            provider: "openrouter",
            contextWindow: 128_000
        )

        /// 所有可用模型
        static let allModels: [ModelInfo] = [
            deepseekV31, deepseekR1_0528, gpt41, claudeOpus4, o4Mini, qwen3_32b_instruct,
            deepseekChat, gemini25Flash, gemini25Pro, llama4Maverick,
            mistralLarge, claudeSonnet4, gpt4o, qwen3_235b,
            deepseekR1, claudeHaiku4, gpt4oMini, llama4Scout,
            gemini25FlashLite, mistralSmall, qwen3_32b,
        ]
    }
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
    /// 权限确认 UI 已实现，default 模式下非只读工具会弹窗确认
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
    /// W2 fix: 添加专用的 keychain 错误 case，而非将 Keychain 错误映射到 fileSystemError
    case keychainError(String)

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
        case .keychainError(let msg): return "Keychain 错误: \(msg)"
        }
    }
}