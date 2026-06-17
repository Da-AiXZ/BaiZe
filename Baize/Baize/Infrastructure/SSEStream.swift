import Foundation

/// SSE 协议解析器 — 基于 URLSession AsyncThrowingStream
/// 解析 Server-Sent Events 流：data: {...}、data: [DONE]
/// 支持 content delta、tool_call delta、finish_reason 等事件类型
struct SSEStream {

    // MARK: - SSE Event Types

    /// SSE 解析后的事件
    enum SSEEvent {
        /// 内容增量（LLM 文本输出）
        case delta(String)
        /// 工具调用开始（id + name）
        case toolCallBegin(id: String, name: String)
        /// 工具调用参数增量
        case toolCallDelta(id: String, argumentsDelta: String)
        /// 流式结束
        case done
        /// 心跳注释（SSE comment lines starting with :）
        case comment(String)
    }

    // MARK: - Public API

    /// 解析 SSE 流，返回 AsyncThrowingStream<SSEEvent>
    /// - Parameter urlRequest: 已构建的 URLRequest（含 stream=true）
    /// - Returns: AsyncThrowingStream of SSEEvent
    func parse(urlRequest: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    // 验证 HTTP 状态码
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw BaizeError.apiError("HTTP 状态码异常: \(statusCode)")
                    }

                    apiLogger.info("SSE stream connected, status: \(httpResponse.statusCode)")

                    // 逐行解析 SSE 事件
                    var buffer = ""
                    for try await line in bytes.lines {
                        buffer += line + "\n"

                        // SSE 事件以双换行符分隔
                        if line.isEmpty {
                            // 处理缓冲区中的完整事件
                            let events = parseBuffer(buffer)
                            for event in events {
                                continuation.yield(event)
                            }
                            buffer = ""
                        }
                    }

                    // 处理缓冲区中剩余的数据
                    if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let events = parseBuffer(buffer)
                        for event in events {
                            continuation.yield(event)
                        }
                    }

                    apiLogger.info("SSE stream completed")
                    continuation.finish()
                } catch {
                    apiLogger.error("SSE stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Parsing Logic

    /// 解析缓冲区中的 SSE 事件块
    /// SSE 格式（RFC 8895）：
    ///   多行 data 用 \n 拼接（W6 fix）
    ///   data: line1
    ///   data: line2
    ///   → 实际数据为 "line1\nline2"
    ///   data: {"choices":[{"delta":{"content":"..."}}]}
    ///   data: {"choices":[{"delta":{"tool_calls":[...]}}]}
    ///   data: [DONE]
    private func parseBuffer(_ buffer: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)

        // W6 fix: 收集所有 data 行，多行 data 用 \n 拼接（RFC 8895）
        var dataLines: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行（事件分隔符已在调用处处理）
            if trimmedLine.isEmpty { continue }

            // SSE 注释行（以 : 开头）
            if trimmedLine.hasPrefix(":") {
                events.append(.comment(String(trimmedLine.dropFirst())))
                continue
            }

            // SSE data 行 — 累积多行 data
            if trimmedLine.hasPrefix("data:") {
                let dataContent = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataLines.append(dataContent)
            }

            // SSE event: 行（当前仅处理 data: 类型）
            // 忽略 event:, id:, retry: 等其他 SSE 字段
        }

        // W6 fix: 将累积的 data 行用 \n 拼接（RFC 8895 规范）
        if !dataLines.isEmpty {
            let currentData = dataLines.joined(separator: "\n")
            if currentData == "[DONE]" {
                events.append(.done)
            } else {
                let parsedEvents = parseDataJSON(currentData)
                events.append(contentsOf: parsedEvents)
            }
        }

        return events
    }

    /// 解析 SSE data 字段的 JSON 内容
    /// OpenAI Chat Completions SSE JSON 格式：
    /// {
    ///   "id": "chatcmpl-xxx",
    ///   "choices": [{
    ///     "delta": {"content": "..."} 或 {"tool_calls": [...]},
    ///     "finish_reason": null | "stop" | "tool_calls"
    ///   }]
    /// }
    private func parseDataJSON(_ jsonString: String) -> [SSEEvent] {
        guard let jsonData = jsonString.data(using: .utf8) else {
            apiLogger.error("SSE data JSON conversion failed")
            return []
        }

        do {
            let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            guard let choices = json?["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                apiLogger.debug("SSE JSON: no choices array found")
                return []
            }

            var events: [SSEEvent] = []
            let delta = firstChoice["delta"] as? [String: Any] ?? [:]

            // 1. 处理 content delta
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.delta(content))
            }

            // 2. 处理 tool_calls delta
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    let id = toolCall["id"] as? String ?? ""
                    let function = toolCall["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let argumentsDelta = function["arguments"] as? String ?? ""

                    if !name.isEmpty && !id.isEmpty {
                        // 工具调用开始
                        events.append(.toolCallBegin(id: id, name: name))
                    }
                    if !argumentsDelta.isEmpty {
                        // 工具调用参数增量
                        events.append(.toolCallDelta(id: id, argumentsDelta: argumentsDelta))
                    }
                }
            }

            // 3. 处理 finish_reason
            if let finishReason = firstChoice["finish_reason"] as? String, finishReason != "null" {
                // finishReason 在 SSE chunk 中通常为 null
                // 当 finishReason 非空时，流即将结束
                if finishReason == "stop" || finishReason == "tool_calls" {
                    // 不在此处 yield .done，由 [DONE] 标记流结束
                }
            }

            return events
        } catch {
            apiLogger.error("SSE JSON parse error: \(error.localizedDescription)")
            return []
        }
    }
}