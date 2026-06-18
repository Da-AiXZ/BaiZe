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
                        apiLogger.error("Custom provider: API key not found in keychain")
                        continuation.finish(throwing: ProviderError.notConfigured("custom"))
                        return
                    }

                    let endpoint = self.getEndpoint()
                    // 使用 UserDefaults 中的模型名，而非 APIGateway 传入的参数
                    let actualModel = self.getModel()
                    apiLogger.info("Custom provider: starting stream — model=\(actualModel), endpoint=\(endpoint), messages=\(messages.count), tools=\(tools.count)")

                    let openAIMessages = messages.toOpenAIMergedFormat()
                    let openAITools = tools.isEmpty ? nil : tools.map { $0.toOpenAIFormat() }

                    apiLogger.debug("Custom provider: request messages count=\(openAIMessages.count), tools count=\(openAITools?.count ?? 0)")

                    let urlRequest = try OpenAICompatibleHelper.buildRequest(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        messages: openAIMessages,
                        tools: openAITools,
                        model: actualModel
                    )

                    let sseStream = SSEStream()
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    var hasContent = false
                    var hasError = false
                    var errorDetail = ""

                    for try await event in sseEvents {
                        let chunks = OpenAICompatibleHelper.interpretSSEEvent(event)
                        for chunk in chunks {
                            // 检测错误响应
                            if case .done(let finishReason) = chunk, finishReason.hasPrefix("error:") {
                                hasError = true
                                errorDetail = finishReason
                                apiLogger.error("Custom provider: API returned error in SSE: \(finishReason)")
                            }
                            // 检测有内容
                            if case .textDelta = chunk {
                                hasContent = true
                            }
                            continuation.yield(chunk)
                        }
                    }

                    // 空响应检测：流结束但没有任何内容
                    if hasError {
                        let msg = errorDetail.replacingOccurrences(of: "error:", with: "").trimmingCharacters(in: .whitespaces)
                        apiLogger.error("Custom provider: stream ended with API error: \(msg)")
                        continuation.finish(throwing: ProviderError.apiError("API 返回错误: \(msg)"))
                    } else if !hasContent {
                        apiLogger.error("Custom provider: stream completed but no content (model=\(actualModel), endpoint=\(endpoint), tools=\(tools.count))")
                        let hint: String
                        if tools.count > 0 {
                            hint = "可能原因：1) 此模型不支持 function calling（tools），尝试用不携带 tools 的请求；2) 模型名错误；3) API Key 权限不足。"
                        } else {
                            hint = "可能原因：模型名错误或 API Key 无效。"
                        }
                        continuation.finish(throwing: ProviderError.apiError("API 返回了空响应。\(hint) 模型: \(actualModel), 端点: \(endpoint)"))
                    } else {
                        continuation.finish()
                    }
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
