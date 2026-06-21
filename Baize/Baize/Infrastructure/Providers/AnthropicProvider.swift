import Foundation

/// Anthropic Provider — 调用 Anthropic Messages API
/// 实现 Anthropic 特有的 SSE 事件解释逻辑和请求构建
struct AnthropicProvider: LLMProvider {

    // MARK: - LLMProvider Conformance

    let id = "anthropic"
    let displayName = "Anthropic"
    let supportsFunctionCalling = true

    let availableModels: [ModelInfo] = BaizeModels.Anthropic.allModels

    private let keychainService: KeychainService

    var isConfigured: Bool { getAPIKey() != nil }

    // MARK: - Initialization

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // MARK: - Stream Complete

    /// 发送 Anthropic Messages 请求，返回 SSE 流式响应
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
                    // 1. 读取 API Key
                    guard let apiKey = self.getAPIKey() else {
                        continuation.finish(throwing: ProviderError.notConfigured("anthropic"))
                        return
                    }
                    apiLogger.info("Anthropic provider: API key loaded, starting stream for model: \(model)")

                    // 2. 转换消息为 Anthropic 格式
                    let (system, anthropicMessages) = messages.toAnthropicMessages()
                    let anthropicTools = tools.isEmpty ? nil : tools.map { $0.toAnthropicFormat() }

                    // 3. 构建 URLRequest
                    let urlRequest = try self.buildRequest(
                        apiKey: apiKey,
                        messages: anthropicMessages,
                        tools: anthropicTools,
                        model: model,
                        system: system
                    )

                    // 4. 通过 SSEStream 解析流式响应
                    let sseStream = SSEStream()
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    // 5. 消费 SSE 事件，使用 Anthropic 特定解释逻辑
                    var context = AnthropicStreamContext()
                    for try await event in sseEvents {
                        let chunks = self.interpretSSEEvent(event, context: &context)
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                } catch {
                    apiLogger.error("Anthropic provider stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Connection Verification

    /// 验证 Anthropic API 连接是否可用
    func verifyConnection() async -> Bool {
        guard let apiKey = getAPIKey() else {
            apiLogger.error("Anthropic provider: API key not configured")
            return false
        }

        guard let url = URL(string: BaizeAPI.anthropicEndpoint) else {
            apiLogger.error("Invalid Anthropic endpoint URL")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BaizeAPI.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(BaizeAPI.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 发送最小请求体验证连接
        let body: [String: Any] = [
            "model": "claude-haiku-4-20250414",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }

            let connected = (200...299).contains(httpResponse.statusCode)
            apiLogger.info("Anthropic connection verification: \(connected) (status: \(httpResponse.statusCode))")
            return connected
        } catch {
            apiLogger.error("Anthropic connection verification failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Methods

    /// 从 Keychain 获取 Anthropic API Key
    private func getAPIKey() -> String? {
        let key = keychainService.load(key: BaizeAPI.anthropicKeyKeychainKey)
        return (key != nil && !key!.isEmpty) ? key : nil
    }

    /// 构建 Anthropic Messages API URLRequest
    /// - Parameters:
    ///   - apiKey: Anthropic API Key
    ///   - messages: 已格式化的 Anthropic 消息数组
    ///   - tools: 已格式化的 Anthropic 工具定义数组，可选
    ///   - model: 模型名称
    ///   - system: 顶层 system 提示，可选
    /// - Returns: 构建好的 URLRequest
    private func buildRequest(
        apiKey: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        model: String,
        system: String?
    ) throws -> URLRequest {
        guard let url = URL(string: BaizeAPI.anthropicEndpoint) else {
            throw ProviderError.apiError("Invalid Anthropic endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BaizeAPI.streamTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(BaizeAPI.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 构建请求 Body
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "messages": messages,
        ]

        // 添加 system 提示（Anthropic 使用顶层 system 字段）
        if let system = system, !system.isEmpty {
            body["system"] = system
        }

        // 添加 tools 定义（如果有）
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
            apiLogger.debug("Anthropic request body serialized: \(bodyData.count) bytes for model: \(model)")
        } catch {
            apiLogger.error("Failed to serialize Anthropic request body for model: \(model) — \(error.localizedDescription)")
            throw ProviderError.apiError("请求体序列化失败: \(error.localizedDescription)")
        }

        return request
    }

    /// 解释 Anthropic SSE 事件为 LLMChunk
    /// Anthropic SSE 事件流：
    ///   event: message_start → 忽略（初始化消息上下文）
    ///   event: content_block_start + type: tool_use → .toolCallBegin(id, name)
    ///   event: content_block_start + type: text → 忽略
    ///   event: content_block_delta + delta.type: text_delta → .textDelta(text)
    ///   event: content_block_delta + delta.type: input_json_delta → .toolCallDelta(id, partial_json)
    ///   event: content_block_stop → 忽略
    ///   event: message_delta → 记录 stop_reason
    ///   event: message_stop → .done(finishReason: stop_reason)
    /// - Parameters:
    ///   - event: SSE 原始事件
    ///   - context: 流式上下文（跟踪当前 content_block id）
    /// - Returns: 解释后的 LLMChunk 数组
    private func interpretSSEEvent(
        _ event: SSEStream.SSEEvent,
        context: inout AnthropicStreamContext
    ) -> [LLMChunk] {
        let eventType = event.event
        let data = event.data

        // 解析 data JSON
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            apiLogger.debug("Anthropic SSE: failed to parse data JSON")
            return []
        }

        var chunks: [LLMChunk] = []

        switch eventType {
        case "message_start":
            // 初始化消息，忽略
            apiLogger.debug("Anthropic SSE: message_start")

        case "content_block_start":
            // 内容块开始
            let type = json["type"] as? String ?? ""
            if type == "tool_use" {
                let id = json["id"] as? String ?? ""
                let name = json["name"] as? String ?? ""
                context.currentToolUseId = id
                chunks.append(.toolCallBegin(id: id, name: name))
                apiLogger.debug("Anthropic SSE: tool_use block start id=\(id) name=\(name)")
            } else {
                // text block start，忽略
                apiLogger.debug("Anthropic SSE: text block start")
            }

        case "content_block_delta":
            // 内容块增量
            let delta = json["delta"] as? [String: Any] ?? [:]
            let deltaType = delta["type"] as? String ?? ""

            if deltaType == "text_delta" {
                let text = delta["text"] as? String ?? ""
                if !text.isEmpty {
                    chunks.append(.textDelta(text))
                }
            } else if deltaType == "input_json_delta" {
                let partialJson = delta["partial_json"] as? String ?? ""
                let toolUseId = context.currentToolUseId ?? ""
                if !partialJson.isEmpty && !toolUseId.isEmpty {
                    chunks.append(.toolCallDelta(id: toolUseId, argumentsDelta: partialJson))
                }
            }

        case "content_block_stop":
            // 内容块结束，清理上下文
            context.currentToolUseId = nil
            apiLogger.debug("Anthropic SSE: content_block_stop")

        case "message_delta":
            // 消息级增量，记录 stop_reason
            let delta = json["delta"] as? [String: Any] ?? [:]
            if let stopReason = delta["stop_reason"] as? String {
                context.stopReason = stopReason
                apiLogger.debug("Anthropic SSE: message_delta stop_reason=\(stopReason)")
            }
            // T04: 解析 usage 字段（Anthropic 在 message_delta 事件返回 token 用量）
            // 格式：{"usage": {"input_tokens": 10, "output_tokens": 20}}
            // 注意：input_tokens 是本次请求的完整输入（含 system+messages），output_tokens 是累积输出
            if let usage = json["usage"] as? [String: Any] {
                let promptTokens = usage["input_tokens"] as? Int ?? 0
                let completionTokens = usage["output_tokens"] as? Int ?? 0
                chunks.append(.usage(LLMUsage(promptTokens: promptTokens, completionTokens: completionTokens)))
            }

        case "message_stop":
            // 消息结束
            let finishReason = context.stopReason ?? "end_turn"
            chunks.append(.done(finishReason: finishReason))
            apiLogger.debug("Anthropic SSE: message_stop, finishReason=\(finishReason)")

        case "ping":
            // 心跳，忽略
            break

        default:
            // 未知事件类型，忽略
            if let eventType = eventType {
                apiLogger.debug("Anthropic SSE: unknown event type '\(eventType)'")
            }
        }

        return chunks
    }
}

// MARK: - Anthropic Stream Context

/// Anthropic SSE 流式上下文 — 跟踪当前 content_block 的状态
/// 因为 SSE 事件是增量传输的，需要跨事件保持上下文
struct AnthropicStreamContext: Sendable {
    /// 当前 tool_use content_block 的 ID
    /// 用于在 content_block_delta 事件中关联 tool_call delta
    var currentToolUseId: String? = nil

    /// 消息结束原因（从 message_delta 事件中收集）
    var stopReason: String? = nil
}
