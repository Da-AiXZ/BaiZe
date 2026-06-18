import Foundation

/// 自定义 OpenAI 兼容 Provider — 支持用户自填端点 URL 和模型名
/// 适用于 DeepSeek 官方、Moonshot、Together AI 等所有 OpenAI 兼容 API
struct CustomOpenAIProvider: LLMProvider {

    let id = "custom"
    let displayName = "自定义 (OpenAI 兼容)"
    let supportsFunctionCalling = true

    // 模型列表为空 — 由用户手动输入模型名
    let availableModels: [ModelInfo] = []

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
        tools: [ToolDefinition],
        model: String
    ) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = self.getAPIKey() else {
                        continuation.finish(throwing: ProviderError.notConfigured("custom"))
                        return
                    }

                    let endpoint = self.getEndpoint()
                    // 使用 UserDefaults 中的模型名，而非 APIGateway 传入的参数
                    // 修复：APIGateway 的 activeModel 可能还是默认值 "gpt-4.1"
                    let actualModel = self.getModel()
                    apiLogger.info("Custom provider: starting stream for model: \(actualModel) at endpoint: \(endpoint)")

                    let openAIMessages = messages.toOpenAIMergedFormat()
                    let openAITools = tools.isEmpty ? nil : tools.map { $0.toOpenAIFormat() }

                    let urlRequest = try OpenAICompatibleHelper.buildRequest(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        messages: openAIMessages,
                        tools: openAITools,
                        model: actualModel
                    )

                    let sseStream = SSEStream()
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    for try await event in sseEvents {
                        let chunks = OpenAICompatibleHelper.interpretSSEEvent(event)
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                } catch {
                    apiLogger.error("Custom provider stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Connection Verification

    /// 验证自定义 API 连接是否可用
    func verifyConnection() async -> Bool {
        guard let apiKey = getAPIKey() else {
            apiLogger.error("Custom provider: API key not configured")
            return false
        }
        let endpoint = getEndpoint()
        let model = getModel()
        apiLogger.info("Custom provider: verifying connection at \(endpoint) with model \(model)")
        return await OpenAICompatibleHelper.verifyConnection(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model
        )
    }

    // MARK: - Private Methods

    /// 从 Keychain 获取自定义 Provider API Key
    private func getAPIKey() -> String? {
        let key = keychainService.load(key: BaizeAPI.customProviderKeyKeychainKey)
        return (key != nil && !key!.isEmpty) ? key : nil
    }

    /// 从 UserDefaults 读取自定义端点 URL
    private func getEndpoint() -> String {
        UserDefaults.standard.string(forKey: BaizeAPI.customEndpointUDKey) ?? BaizeAPI.deepSeekEndpoint
    }

    /// 从 UserDefaults 读取自定义模型名
    private func getModel() -> String {
        UserDefaults.standard.string(forKey: BaizeAPI.customModelUDKey) ?? "deepseek-chat"
    }
}
