import Foundation

/// OpenAI Chat Completions API 调用网关 — Actor 并发模型
/// 负责：构建请求、发送 SSE 流式请求、解析响应、累积 tool_call 参数
/// 通过 KeychainService 读取 API Key
/// 返回 AsyncThrowingStream<LLMChunk> 供 AgentLoop 消费
actor APIGateway {

    // MARK: - Properties

    /// SSE 流解析器
    private let sseStream = SSEStream()

    /// Keychain 服务实例
    private let keychainService: KeychainService

    /// 当前活跃的 SSE stream task（用于取消）
    private var activeTask: Task<Void, Never>?

    // MARK: - LLM Chunk Types

    /// LLM 响应增量 chunk — AgentLoop 消费的类型
    enum LLMChunk {
        /// 文本增量
        case textDelta(String)
        /// 工具调用开始（id + name）
        case toolCallBegin(id: String, name: String)
        /// 工具调用参数增量
        case toolCallDelta(id: String, argumentsDelta: String)
        /// 流式完成
        case done(finishReason: String)
    }

    // MARK: - Initialization

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // MARK: - Public API

    /// 发送 Chat Completions 请求，返回 SSE 流式响应
    /// - Parameters:
    ///   - messages: 对话消息数组
    ///   - tools: 工具定义数组（OpenAI function calling 格式）
    ///   - model: 模型名称，默认 gpt-4o
    /// - Returns: AsyncThrowingStream<LLMChunk> 供 AgentLoop for-await 消费
    func streamComplete(
        messages: [Message],
        tools: [ToolDefinition],
        model: String = BaizeAPI.defaultModel
    ) -> AsyncThrowingStream<LLMChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. 读取 API Key
                    let apiKey = try getAPIKey()
                    apiLogger.info("API key loaded, starting stream for model: \(model)")

                    // 2. 构建 URLRequest
                    let urlRequest = buildRequest(
                        apiKey: apiKey,
                        messages: messages,
                        tools: tools,
                        model: model
                    )

                    // 3. 通过 SSEStream 解析流式响应
                    let sseEvents = sseStream.parse(urlRequest: urlRequest)

                    // 4. 状态：累积 tool_call 参数
                    var pendingToolCalls: [String: PendingToolCall] = [:]

                    // 5. 消费 SSE 事件，转换为 LLMChunk
                    for try await event in sseEvents {
                        switch event {
                        case .delta(let content):
                            continuation.yield(.textDelta(content))

                        case .toolCallBegin(id: let id, name: let name):
                            pendingToolCalls[id] = PendingToolCall(id: id, name: name, arguments: "")
                            continuation.yield(.toolCallBegin(id: id, name: name))

                        case .toolCallDelta(id: let id, argumentsDelta: let delta):
                            if let pending = pendingToolCalls[id] {
                                pendingToolCalls[id] = PendingToolCall(
                                    id: pending.id,
                                    name: pending.name,
                                    arguments: pending.arguments + delta
                                )
                            }
                            continuation.yield(.toolCallDelta(id: id, argumentsDelta: delta))

                        case .done:
                            continuation.yield(.done(finishReason: "stop"))
                            apiLogger.info("SSE stream done, yielded \(pendingToolCalls.count) tool calls")

                        case .comment(let text):
                            apiLogger.debug("SSE comment: \(text)")
                        }
                    }

                    continuation.finish()
                } catch {
                    apiLogger.error("APIGateway stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 取消当前活跃的 SSE stream
    func cancelStream() {
        activeTask?.cancel()
        activeTask = nil
        apiLogger.info("SSE stream cancelled")
    }

    // MARK: - Private Methods

    /// 从 Keychain 获取 API Key
    private func getAPIKey() throws -> String {
        guard let apiKey = keychainService.load(key: BaizeAPI.openAIKeyKeychainKey),
              !apiKey.isEmpty else {
            throw BaizeError.apiKeyMissing
        }
        return apiKey
    }

    /// 构建 OpenAI Chat Completions URLRequest
    private func buildRequest(
        apiKey: String,
        messages: [Message],
        tools: [ToolDefinition],
        model: String
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: BaizeAPI.openAIEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = BaizeAPI.streamTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 构建请求 Body
        // 修复 C1/C2：使用 toOpenAIMergedFormat() 合并连续 toolCall 消息为
        // 单个 assistant 消息，符合 OpenAI API 要求
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.toOpenAIMergedFormat(),
        ]

        // 添加 tools 定义（如果有）
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toOpenAIFormat() }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - Pending Tool Call

/// 累积中的工具调用（SSE tool_call 参数是增量传输的）
private struct PendingToolCall {
    let id: String
    let name: String
    var arguments: String
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
}