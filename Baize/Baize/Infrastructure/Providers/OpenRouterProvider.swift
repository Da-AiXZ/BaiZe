import Foundation

/// OpenRouter Provider — 通过 OpenRouter 路由调用多种 LLM
/// 使用 OpenAI 兼容格式（与 OpenAIProvider 类似），但使用 OpenRouter 端点和额外请求头
struct OpenRouterProvider: LLMProvider {

    // MARK: - LLMProvider Conformance

    let id = "openrouter"
    let displayName = "OpenRouter"
    let supportsFunctionCalling = true

    let availableModels: [ModelInfo] = BaizeModels.OpenRouter.allModels

    private let keychainService: KeychainService

    var isConfigured: Bool { getAPIKey() != nil }

    /// OpenRouter 额外请求头
    private let additionalHeaders: [String: String] = [
        "HTTP-Referer": "https://baize.app",
        "X-Title": "Baize",
    ]

    // MARK: - Initialization

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // MARK: - Stream Complete

    /// 发送 Chat Completions 请求，返回 SSE 流式响应
    /// - Parameters:
    ///   - messages: 对话消息数组
    ///   - tools: 工具定义数组
    ///   - model: 模型名称（OpenRouter 格式，如 "deepseek/deepseek-chat"）
    /// - Returns: AsyncThrowingStream<LLMChunk> 供 AgentLoop for-await 消费
    func streamComplete(
        messages: [Message],
        tools: [ToolDefinition],
        model: String
    ) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. 读取 API Key
                    guard let apiKey = self.getAPIKey() else {
                        continuation.finish(throwing: ProviderError.notConfigured("openrouter"))
                        return
                    }
                    apiLogger.info("OpenRouter provider: API key loaded, starting stream for model: \(model)")

                    // 2. 构建消息和工具定义
                    let openAIMessages = messages.toOpenAIMergedFormat()
                    let openAITools = tools.isEmpty ? nil : tools.map { $0.toOpenAIFormat() }

                    // 3. 构建 URLRequest（使用 OpenRouter 端点 + 额外请求头）
                    let urlRequest = try OpenAICompatibleHelper.buildRequest(
                        endpoint: BaizeAPI.openRouterEndpoint,
                        apiKey: apiKey,
                        additionalHeaders: self.additionalHeaders,
                        messages: openAIMessages,
                        tools: openAITools,
                        model: model
                    )

                    // 4. 通过 SSEStream 解析流式响应
                    let sseStream = SSEStream()
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    // 5. 消费 SSE 事件，解释为 LLMChunk
                    for try await event in sseEvents {
                        let chunks = OpenAICompatibleHelper.interpretSSEEvent(event)
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                } catch {
                    apiLogger.error("OpenRouter provider stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Connection Verification

    /// 验证 OpenRouter API 连接是否可用
    func verifyConnection() async -> Bool {
        guard let apiKey = getAPIKey() else {
            apiLogger.error("OpenRouter provider: API key not configured")
            return false
        }
        return await OpenAICompatibleHelper.verifyConnection(
            endpoint: BaizeAPI.openRouterEndpoint,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders,
            model: "openai/gpt-4o-mini"  // Valid OpenRouter model ID
        )
    }

    // MARK: - Private Methods

    /// 从 Keychain 获取 OpenRouter API Key
    private func getAPIKey() -> String? {
        let key = keychainService.load(key: BaizeAPI.openRouterKeyKeychainKey)
        return (key != nil && !key!.isEmpty) ? key : nil
    }
}
