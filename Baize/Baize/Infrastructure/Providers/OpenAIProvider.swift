import Foundation

/// OpenAI Provider — 直接调用 OpenAI Chat Completions API
/// 使用 OpenAICompatibleHelper 构建请求和解释 SSE 事件
struct OpenAIProvider: LLMProvider {

    // MARK: - LLMProvider Conformance

    let id = "openai"
    let displayName = "OpenAI"
    let supportsFunctionCalling = true

    let availableModels: [ModelInfo] = BaizeModels.OpenAI.allModels

    private let keychainService: KeychainService

    var isConfigured: Bool { getAPIKey() != nil }

    // MARK: - Initialization

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // MARK: - Stream Complete

    /// 发送 Chat Completions 请求，返回 SSE 流式响应
    /// - Parameters:
    ///   - messages: 对话消息数组
    ///   - tools: 工具定义数组
    ///   - model: 模型名称
    /// - Returns: AsyncThrowingStream<LLMChunk> 供 AgentLoop for-await 消费
    func streamComplete(
        messages: [Message],
        tools: [APIGateway.ToolDefinition],
        model: String
    ) -> AsyncThrowingStream<APIGateway.LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. 读取 API Key
                    guard let apiKey = self.getAPIKey() else {
                        continuation.finish(throwing: ProviderError.notConfigured("openai"))
                        return
                    }
                    apiLogger.info("OpenAI provider: API key loaded, starting stream for model: \(model)")

                    // 2. 构建消息和工具定义
                    let openAIMessages = messages.toOpenAIMergedFormat()
                    let openAITools = tools.isEmpty ? nil : tools.map { $0.toOpenAIFormat() }

                    // 3. 构建 URLRequest
                    let urlRequest = try OpenAICompatibleHelper.buildRequest(
                        endpoint: BaizeAPI.openAIEndpoint,
                        apiKey: apiKey,
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
                    apiLogger.error("OpenAI provider stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Connection Verification

    /// 验证 OpenAI API 连接是否可用
    func verifyConnection() async -> Bool {
        guard let apiKey = getAPIKey() else {
            apiLogger.error("OpenAI provider: API key not configured")
            return false
        }
        return await OpenAICompatibleHelper.verifyConnection(
            endpoint: BaizeAPI.openAIEndpoint,
            apiKey: apiKey
        )
    }

    // MARK: - Private Methods

    /// 从 Keychain 获取 OpenAI API Key
    private func getAPIKey() -> String? {
        let key = keychainService.load(key: BaizeAPI.openAIKeyKeychainKey)
        return (key != nil && !key!.isEmpty) ? key : nil
    }
}
