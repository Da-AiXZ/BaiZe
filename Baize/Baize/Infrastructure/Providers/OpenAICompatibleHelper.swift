import Foundation

/// OpenAI 兼容 API 请求构建与 SSE 解释工具
/// 从原 APIGateway 迁移的 OpenAI Chat Completions 请求构建逻辑和 SSE 事件解释逻辑
/// 被 OpenAIProvider 和 OpenRouterProvider 共用
enum OpenAICompatibleHelper {

    // MARK: - Stream State (per-request)
    // OpenAI 流式 tool_calls 用 index 标识，后续 chunk 没有 id，只有 index
    // 需要维护 index → id 映射，否则 arguments delta 会丢失
    // 注意：每次新请求前需要清空
    static var toolCallIndexMap: [Int: String] = [:]

    /// 重置流式状态（每次 streamComplete 调用前由 Provider 调用）
    static func resetStreamState() {
        toolCallIndexMap.removeAll()
    }

    // MARK: - Request Building

    /// 构建 OpenAI Chat Completions 兼容的 URLRequest
    /// - Parameters:
    ///   - endpoint: API 端点 URL
    ///   - apiKey: API Key
    ///   - additionalHeaders: 额外 HTTP 请求头（如 OpenRouter 的 HTTP-Referer）
    ///   - messages: 已格式化的消息数组（OpenAI 格式）
    ///   - tools: 已格式化的工具定义数组（OpenAI 格式），可选
    ///   - model: 模型名称
    /// - Returns: 构建好的 URLRequest
    static func buildRequest(
        endpoint: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        model: String,
        extraBody: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw ProviderError.apiError("Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BaizeAPI.streamTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 添加额外请求头
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 构建请求 Body
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages,
        ]

        // 添加 tools 定义（如果有）
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        // 合并 extraBody 字段（如 DeepSeek V4 的 thinking 参数）
        if let extra = extraBody {
            for (key, value) in extra {
                body[key] = value
            }
        }

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
            // 诊断：记录请求体详情（仅记录关键字段，避免日志过大）
            let toolCount = tools?.count ?? 0
            apiLogger.debug("OpenAI-compat request: model=\(model), stream=true, messages=\(messages.count), tools=\(toolCount), body=\(bodyData.count) bytes")
            if toolCount > 0 {
                let toolNames = (tools ?? []).compactMap { $0["function"] as? [String: Any] }.compactMap { $0["name"] as? String }
                apiLogger.debug("OpenAI-compat request tools: \(toolNames.joined(separator: ", "))")
            }
            if let extra = extraBody {
                apiLogger.debug("OpenAI-compat request extraBody: \(extra)")
            }
        } catch {
            apiLogger.error("Failed to serialize request body for model: \(model) — \(error.localizedDescription)")
            throw ProviderError.apiError("请求体序列化失败: \(error.localizedDescription)")
        }

        return request
    }

    // MARK: - SSE Event Interpretation

    /// 将 SSE 原始事件解释为 LLMChunk
    /// 解析 OpenAI Chat Completions SSE JSON 格式：
    /// {
    ///   "id": "chatcmpl-xxx",
    ///   "choices": [{
    ///     "delta": {"content": "..."} 或 {"tool_calls": [...]},
    ///     "finish_reason": null | "stop" | "tool_calls"
    ///   }]
    /// }
    /// - Parameter event: SSE 原始事件
    /// - Returns: 解释后的 LLMChunk 数组
    static func interpretSSEEvent(_ event: SSEStream.SSEEvent) -> [LLMChunk] {
        let data = event.data

        // [DONE] 标记流结束
        if data == "[DONE]" {
            return [.done(finishReason: "stop")]
        }

        // 解析 JSON
        guard let jsonData = data.data(using: .utf8) else {
            apiLogger.error("SSE data JSON conversion failed")
            return []
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                apiLogger.debug("SSE JSON parse failed, data: \(data.prefix(200))")
                return []
            }

            // 先检查是否为 API 错误响应（某些 API 在 SSE 流中返回错误）
            if let errorInfo = json["error"] as? [String: Any] {
                let message = errorInfo["message"] as? String ?? "未知错误"
                let errorType = errorInfo["type"] as? String ?? "api_error"
                apiLogger.error("SSE API error: \(errorType) — \(message)")
                // 返回一个特殊的 done chunk，附带错误信息作为 finishReason
                return [.done(finishReason: "error: \(message)")]
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                apiLogger.debug("SSE JSON: no choices array found, data: \(data.prefix(200))")
                return []
            }

            var chunks: [LLMChunk] = []
            let delta = firstChoice["delta"] as? [String: Any] ?? [:]

            // 1. 处理 reasoning_content delta（DeepSeek V4 thinking mode 的思维链内容）
            // thinking mode 下，思维链在 reasoning_content 字段，不在 content 字段
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                chunks.append(.textDelta(reasoning))
            }

            // 2. 处理 content delta（最终答案）
            if let content = delta["content"] as? String, !content.isEmpty {
                chunks.append(.textDelta(content))
            }

            // 3. 处理 tool_calls delta
            // OpenAI 流式格式：第一个 chunk 有 id+name，后续 chunk 只有 index+arguments delta
            // 必须用 index 跟踪，因为后续 chunk 没有 id
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    let id = toolCall["id"] as? String ?? ""
                    let index = toolCall["index"] as? Int ?? 0
                    let function = toolCall["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    // arguments 可能是 String（标准 OpenAI 流式 delta）或已序列化的对象
                    let argumentsDelta: String
                    if let argsStr = function["arguments"] as? String {
                        argumentsDelta = argsStr
                    } else if let argsObj = function["arguments"] as? [String: Any] {
                        if let data = try? JSONSerialization.data(withJSONObject: argsObj),
                           let str = String(data: data, encoding: .utf8) {
                            argumentsDelta = str
                        } else {
                            argumentsDelta = ""
                        }
                    } else {
                        argumentsDelta = ""
                    }

                    // 诊断日志
                    if !name.isEmpty {
                        apiLogger.info("SSE tool_call begin: id=\(id), index=\(index), name=\(name)")
                    }
                    if !argumentsDelta.isEmpty {
                        apiLogger.info("SSE tool_call delta: index=\(index), args=\(argumentsDelta.prefix(100))")
                    }

                    if !name.isEmpty && !id.isEmpty {
                        // 工具调用开始 — 注册 index → id 映射
                        Self.toolCallIndexMap[index] = id
                        chunks.append(.toolCallBegin(id: id, name: name))
                    }
                    if !argumentsDelta.isEmpty {
                        // 参数增量 — 用 index 查找对应的 id
                        let resolvedId = id.isEmpty ? (Self.toolCallIndexMap[index] ?? id) : id
                        if !resolvedId.isEmpty {
                            chunks.append(.toolCallDelta(id: resolvedId, argumentsDelta: argumentsDelta))
                        }
                    }
                }
            }

            // 3. 处理 finish_reason
            if let finishReason = firstChoice["finish_reason"] as? String,
               finishReason != "null" && !finishReason.isEmpty {
                if finishReason == "stop" || finishReason == "tool_calls" {
                    // finishReason 信号，流即将结束
                    // 不在此处 yield .done，由 [DONE] 标记流结束
                }
            }

            return chunks
        } catch {
            apiLogger.error("SSE JSON parse error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Connection Verification

    /// 验证 API 连接是否可用
    /// - Parameters:
    ///   - endpoint: API 端点 URL
    ///   - apiKey: API Key
    ///   - additionalHeaders: 额外 HTTP 请求头
    ///   - model: 验证时使用的模型名称（默认 gpt-4o-mini，OpenRouter 需传 openai/gpt-4o-mini）
    /// - Returns: 连接是否成功
    static func verifyConnection(
        endpoint: String,
        apiKey: String,
        additionalHeaders: [String: String] = [:],
        model: String = "gpt-4o-mini"
    ) async -> Bool {
        guard let url = URL(string: endpoint) else {
            apiLogger.error("Invalid endpoint URL for verification: \(endpoint)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BaizeAPI.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 发送最小请求体验证连接
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }

            // 200 或 401（Key 格式错误但连接成功）都算连接可用
            let connected = (200...299).contains(httpResponse.statusCode)
            apiLogger.info("OpenAI-compat connection verification: \(connected) (status: \(httpResponse.statusCode))")
            return connected
        } catch {
            apiLogger.error("OpenAI-compat connection verification failed: \(error.localizedDescription)")
            return false
        }
    }
}
