import Foundation

/// SSE 协议解析器 — 基于 URLSession AsyncThrowingStream
/// 泛化版本：仅解析 SSE 协议层（event + data 字段），
/// 不包含任何 Provider 特定的 JSON 解释逻辑（迁移到各 Provider Helper）
struct SSEStream {

    // MARK: - SSE Event

    /// SSE 解析后的原始事件 — 仅包含协议层的 event 和 data 字段
    /// Provider 特定解释由各 Provider Helper 负责
    struct SSEEvent: Sendable {
        /// SSE event 字段（如 message_start, content_block_delta 等）
        /// 为 nil 时表示默认事件（无 event: 行）
        let event: String?
        /// SSE data 字段内容（多行 data 用 \n 拼接，RFC 8895）
        let data: String
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
                        // 读取错误响应体，获取 API 返回的具体错误信息
                        var errorBody = ""
                        var collected = 0
                        let maxErrorBytes = 4096
                        for try await byte in bytes {
                            if collected >= maxErrorBytes { break }
                            errorBody.append(Character(UnicodeScalar(byte)))
                            collected += 1
                        }
                        let displayBody = errorBody.isEmpty ? "(空响应体)" : errorBody
                        apiLogger.error("SSE HTTP \(statusCode) error body: \(displayBody)")
                        throw BaizeError.apiError("HTTP \(statusCode): \(displayBody)")
                    }

                    apiLogger.info("SSE stream connected, status: \(httpResponse.statusCode)")

                    // 检查 Content-Type — 如果不是 text/event-stream，可能是 JSON 错误响应
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                    apiLogger.info("SSE response Content-Type: \(contentType)")

                    if !contentType.lowercased().contains("text/event-stream") {
                        // 服务器返回了非 SSE 响应（可能是 JSON 错误）
                        // 读取全部响应体作为错误信息
                        var rawBody = ""
                        var collected = 0
                        let maxBytes = 8192
                        for try await byte in bytes {
                            if collected >= maxBytes { break }
                            rawBody.append(Character(UnicodeScalar(byte)))
                            collected += 1
                        }
                        apiLogger.error("SSE: non-SSE response (Content-Type: \(contentType)), body: \(rawBody)")
                        throw BaizeError.apiError("API 返回了非流式响应 (Content-Type: \(contentType))。响应内容: \(rawBody)")
                    }

                    // 逐行解析 SSE 事件
                    var buffer = ""
                    var totalEventsYielded = 0
                    var lineCount = 0
                    var firstLinesLog: [String] = []

                    for try await line in bytes.lines {
                        lineCount += 1
                        // 记录前 5 行用于诊断
                        if firstLinesLog.count < 5 {
                            firstLinesLog.append(line)
                        }

                        buffer += line + "\n"

                        // SSE 事件以双换行符分隔
                        if line.isEmpty {
                            // 处理缓冲区中的完整事件
                            let events = parseBuffer(buffer)
                            for event in events {
                                continuation.yield(event)
                                totalEventsYielded += 1
                            }
                            buffer = ""
                        }
                    }

                    // 处理缓冲区中剩余的数据
                    if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let events = parseBuffer(buffer)
                        for event in events {
                            continuation.yield(event)
                            totalEventsYielded += 1
                        }
                    }

                    apiLogger.info("SSE stream completed: \(lineCount) lines, \(totalEventsYielded) events")

                    // 如果没有任何 SSE 事件被解析出来，记录原始数据用于诊断
                    if totalEventsYielded == 0 {
                        let rawPreview = firstLinesLog.joined(separator: " | ")
                        apiLogger.error("SSE: 0 events parsed from \(lineCount) lines. First lines: \(rawPreview)")
                    }

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
    ///   event: message_start
    ///   data: {"type":"message_start",...}
    ///   （空行分隔事件）
    ///   多行 data 用 \n 拼接（W6 fix）
    ///   data: line1
    ///   data: line2
    ///   → 实际数据为 "line1\nline2"
    private func parseBuffer(_ buffer: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)

        // 收集当前事件块的字段
        var currentEvent: String? = nil
        var dataLines: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行（事件分隔符已在调用处处理）
            if trimmedLine.isEmpty { continue }

            // SSE 注释行（以 : 开头）— 跳过
            if trimmedLine.hasPrefix(":") { continue }

            // SSE event: 行
            if trimmedLine.hasPrefix("event:") {
                let eventContent = String(trimmedLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                currentEvent = eventContent
            }

            // SSE data: 行 — 累积多行 data
            if trimmedLine.hasPrefix("data:") {
                let dataContent = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataLines.append(dataContent)
            }

            // 忽略 id:, retry: 等其他 SSE 字段
        }

        // W6 fix: 将累积的 data 行用 \n 拼接（RFC 8895 规范）
        if !dataLines.isEmpty {
            let currentData = dataLines.joined(separator: "\n")
            let event = SSEEvent(event: currentEvent, data: currentData)
            events.append(event)
        }

        return events
    }
}
