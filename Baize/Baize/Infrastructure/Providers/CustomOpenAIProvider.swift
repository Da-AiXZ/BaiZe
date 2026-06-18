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
                    let actualModel = self.getModel()
                    apiLogger.info("Custom provider: starting stream — model=\(actualModel), endpoint=\(endpoint), messages=\(messages.count), tools=\(tools.count)")

                    let openAIMessages = messages.toOpenAIMergedFormat()
                    let openAITools = tools.isEmpty ? nil : tools.map { $0.toOpenAIFormat() }

                    // DeepSeek V4 thinking mode 策略：
                    // - thinking mode 默认开启，reasoning_content 在独立字段
                    // - thinking mode 下 tool calls 的 reasoning_content 必须多轮传回，否则 400 错误
                    // - AgentLoop 目前不支持 reasoning_content 多轮传回
                    // - 因此：带 tools 时关闭 thinking mode（避免 400），不带 tools 时保持默认（让用户看到思维链）
                    var extraBody: [String: Any] = [:]
                    if !tools.isEmpty {
                        extraBody["thinking"] = ["type": "disabled"]
                        apiLogger.info("Custom provider: thinking mode DISABLED (tools present, avoids 400 on multi-turn)")
                    }

                    let urlRequest = try OpenAICompatibleHelper.buildRequest(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        messages: openAIMessages,
                        tools: openAITools,
                        model: actualModel,
                        extraBody: extraBody.isEmpty ? nil : extraBody
                    )

                    let sseStream = SSEStream()
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    var hasContent = false
                    var hasError = false
                    var errorDetail = ""
                    var eventCount = 0
                    var firstEventData = ""

                    for try await event in sseEvents {
                        eventCount += 1
                        if eventCount == 1 {
                            firstEventData = event.data
                        }
                        let chunks = OpenAICompatibleHelper.interpretSSEEvent(event)
                        for chunk in chunks {
                            // 检测错误响应
                            if case .done(let finishReason) = chunk, finishReason.hasPrefix("error:") {
                                hasError = true
                                errorDetail = finishReason
                                apiLogger.error("Custom provider: API returned error in SSE: \(finishReason)")
                            }
                            // 检测有内容（content 或 reasoning_content 都算）
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
                        apiLogger.error("Custom provider: stream completed but no content (model=\(actualModel), endpoint=\(endpoint), tools=\(tools.count), events=\(eventCount))")
                        if eventCount > 0 {
                            // 有事件但没 content — 说明 SSE 格式有问题，暴露第一个事件的数据
                            continuation.finish(throwing: ProviderError.apiError("收到 \(eventCount) 个 SSE 事件但无内容。第一个事件数据: \(firstEventData.prefix(500))。模型: \(actualModel)"))
                        } else {
                            continuation.finish(throwing: ProviderError.apiError("API 返回了空响应（0 事件）。模型: \(actualModel), 端点: \(endpoint)"))
                        }
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
