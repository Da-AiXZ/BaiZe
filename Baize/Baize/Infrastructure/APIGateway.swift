import Foundation

/// LLM 响应增量 chunk — AgentLoop 消费的类型
enum LLMChunk: Sendable {
    /// 文本增量
    case textDelta(String)
    /// 工具调用开始（id + name）
    case toolCallBegin(id: String, name: String)
    /// 工具调用参数增量
    case toolCallDelta(id: String, argumentsDelta: String)
    /// 流式完成
    case done(finishReason: String)
}

/// LLM API 调用网关 — Actor 并发模型
/// Phase 2C 重构：委托到 LLMProvider 协议，支持多 Provider 切换
/// 负责：Provider 注册、Provider/模型切换、流式请求委托
/// 通过 KeychainService 读取 API Key
/// 返回 AsyncThrowingStream<LLMChunk> 供 AgentLoop 消费
actor APIGateway {

    // MARK: - Properties

    /// SSE 流解析器（保留用于向后兼容，新代码在 Provider 中创建）
    private let sseStream = SSEStream()

    /// Keychain 服务实例
    private let keychainService: KeychainService

    /// 当前活跃的 SSE stream task（用于取消）
    private var activeTask: Task<Void, Never>?

    /// 已注册的 Provider 字典（id → Provider）
    private var providers: [String: any LLMProvider] = [:]

    /// 当前活跃的 Provider ID
    private var activeProviderId: String = "openai"

    /// 当前活跃的模型名称
    private var activeModel: String = BaizeAPI.defaultModel

    // MARK: - Initialization

    init(keychainService: KeychainService) {
        self.keychainService = keychainService

        // 注册默认 Provider
        let openAIProvider = OpenAIProvider(keychainService: keychainService)
        let anthropicProvider = AnthropicProvider(keychainService: keychainService)
        let openRouterProvider = OpenRouterProvider(keychainService: keychainService)

        providers[openAIProvider.id] = openAIProvider
        providers[anthropicProvider.id] = anthropicProvider
        providers[openRouterProvider.id] = openRouterProvider

        let providerNames = providers.keys.joined(separator: ", ")
        apiLogger.info("APIGateway initialized with providers: \(providerNames)")
    }

    // MARK: - Public API

    /// 发送 Chat Completions 请求，返回 SSE 流式响应
    /// 委托到当前活跃的 Provider 执行
    /// - Parameters:
    ///   - messages: 对话消息数组
    ///   - tools: 工具定义数组
    ///   - model: 模型名称，默认使用 activeModel
    /// - Returns: AsyncThrowingStream<LLMChunk> 供 AgentLoop for-await 消费
    func streamComplete(
        messages: [Message],
        tools: [ToolDefinition],
        model: String? = nil
    ) -> AsyncThrowingStream<LLMChunk, Error> {
        let resolvedModel = model ?? activeModel
        let currentProviderId = activeProviderId

        // 委托到活跃 Provider
        guard let provider = providers[activeProviderId] else {
            apiLogger.error("No active provider registered with id: \(currentProviderId)")
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderError.notRegistered(currentProviderId))
            }
        }

        apiLogger.info("APIGateway: delegating to provider '\(currentProviderId)' with model '\(resolvedModel)'")
        return provider.streamComplete(messages: messages, tools: tools, model: resolvedModel)
    }

    /// 取消当前活跃的 SSE stream
    func cancelStream() {
        activeTask?.cancel()
        activeTask = nil
        apiLogger.info("SSE stream cancelled")
    }

    // MARK: - Provider Management

    /// 注册一个新的 Provider
    /// - Parameter provider: 实现 LLMProvider 协议的 Provider
    func register(provider: any LLMProvider) {
        providers[provider.id] = provider
        apiLogger.info("Provider registered: \(provider.id) (\(provider.displayName))")
    }

    /// 设置当前活跃的 Provider 和模型
    /// - Parameters:
    ///   - providerId: Provider ID
    ///   - model: 模型名称，默认使用 Provider 的第一个推荐模型
    func setActiveProvider(providerId: String, model: String? = nil) throws {
        guard providers[providerId] != nil else {
            throw ProviderError.notRegistered(providerId)
        }

        activeProviderId = providerId

        // 如果指定了模型，使用指定的；否则使用 Provider 的第一个推荐模型
        if let model = model {
            activeModel = model
        } else if let firstModel = providers[providerId]?.availableModels.first {
            activeModel = firstModel.id
        }

        let currentModel = activeModel
        apiLogger.info("Active provider set to '\(providerId)', model: \(currentModel)")
    }

    /// 获取当前活跃的 Provider
    /// - Returns: 当前活跃的 Provider，如果未注册则返回 nil
    func getActiveProvider() -> (any LLMProvider)? {
        providers[activeProviderId]
    }

    /// 获取所有已注册的 Provider
    /// - Returns: Provider 数组
    func getRegisteredProviders() -> [any LLMProvider] {
        Array(providers.values)
    }

    /// 获取当前活跃的 Provider ID
    func getActiveProviderId() -> String {
        activeProviderId
    }

    /// 获取当前活跃的模型名称
    func getActiveModel() -> String {
        activeModel
    }
}

// MARK: - Tool Definition

/// 工具定义 — OpenAI function calling 格式
struct ToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any] // JSON Schema 格式

    /// 转换为 OpenAI tools 参数格式
    func toOpenAIFormat() -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ]
        ]
    }

    /// 转换为 Anthropic tools 参数格式
    /// Anthropic 格式：{name, description, input_schema}
    func toAnthropicFormat() -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "input_schema": parameters,
        ]
    }
}
