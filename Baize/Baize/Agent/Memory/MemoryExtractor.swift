import Foundation

/// 记忆提取器 — 从对话历史中自动提取记忆
///
/// 工作流程：
/// 1. 检查是否开启自动提取（UserDefaults，默认开启）
/// 2. 格式化对话历史为文本（复用 ContextManager.formatMessagesForSummary 模式）
/// 3. 构建 extract prompt（让 LLM 输出 JSON：[{type, content, keywords}]）
/// 4. 调 apiGateway.streamComplete(tools:[]) 收集文本（复用 generateSummary 的 30s 超时降级）
/// 5. 解析 JSON，逐条 memoryStore.appendMemory
///
/// 触发时机：每 BaizeToken.memoryExtractionInterval 轮对话自动触发一次
struct MemoryExtractor {

    /// UserDefaults 键 — 控制自动提取开关
    static let autoExtractionUDKey = "com.baize.memory-auto-extraction"

    // MARK: - Extract

    /// 从会话历史中提取记忆并存储
    /// - Parameters:
    ///   - session: 当前会话（包含对话历史）
    ///   - apiGateway: API 网关（调 LLM 提取记忆）
    ///   - memoryStore: 记忆存储（写入提取的记忆）
    ///   - scope: 记忆作用域（默认 .user）
    func extractAndStore(
        session: ConversationSession,
        apiGateway: APIGateway,
        memoryStore: MemoryStore,
        scope: MemoryScope = .user
    ) async {
        // 1. 检查是否开启自动提取
        guard isAutoExtractionEnabled() else {
            memoryLogger.info("MemoryExtractor: auto extraction disabled, skipping")
            return
        }

        // 2. 格式化对话历史
        let textBlob = formatMessagesForExtraction(session.messages)
        guard !textBlob.isEmpty else {
            memoryLogger.info("MemoryExtractor: empty conversation, skipping extraction")
            return
        }

        // 3. 调 LLM 提取记忆（含 30s 超时降级）
        let extractedMemories: [ExtractedMemory]
        do {
            let response = try await callLLMForExtraction(
                textBlob: textBlob,
                apiGateway: apiGateway
            )
            extractedMemories = parseExtractionResponse(response)
        } catch {
            memoryLogger.warning("MemoryExtractor: LLM extraction failed: \(error.localizedDescription)")
            return
        }

        // 4. 逐条存储
        guard !extractedMemories.isEmpty else {
            memoryLogger.info("MemoryExtractor: no memories extracted")
            return
        }

        for memory in extractedMemories {
            await memoryStore.appendMemory(
                scope: scope,
                content: memory.content,
                type: memory.type,
                keywords: memory.keywords
            )
        }

        memoryLogger.info("MemoryExtractor: extracted and stored \(extractedMemories.count) memories")
    }

    // MARK: - Auto Extraction Toggle

    /// 检查是否开启自动提取（默认开启）
    static func isAutoExtractionEnabled() -> Bool {
        // 如果 key 不存在，默认 true（开启）
        if UserDefaults.standard.object(forKey: autoExtractionUDKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoExtractionUDKey)
    }

    /// 设置自动提取开关
    static func setAutoExtraction(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoExtractionUDKey)
    }

    // MARK: - LLM Call

    /// 调 LLM 提取记忆（复用 ContextManager.generateSummary 的 30s 超时降级模式）
    /// - Parameters:
    ///   - textBlob: 格式化的对话历史文本
    ///   - apiGateway: API 网关
    /// - Returns: LLM 返回的 JSON 文本
    private func callLLMForExtraction(
        textBlob: String,
        apiGateway: APIGateway
    ) async throws -> String {
        let request: [Message] = [
            .system(MemoryExtractor.extractPrompt),
            .user(textBlob)
        ]

        // TaskGroup：提取 vs 30s 超时
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [apiGateway] in
                var response = ""
                let stream = await apiGateway.streamComplete(messages: request, tools: [])
                for try await chunk in stream {
                    if case .textDelta(let text) = chunk {
                        response += text
                    }
                }
                if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw MemoryExtractorError.emptyResponse
                }
                return response
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(BaizeSummary.timeoutSeconds * 1_000_000_000))
                throw MemoryExtractorError.timeout
            }

            let result = try await group.next() ?? ""
            group.cancelAll()
            return result
        }
    }

    // MARK: - Message Formatting

    /// 格式化消息列表为记忆提取文本（复用 ContextManager.formatMessagesForSummary 模式）
    private func formatMessagesForExtraction(_ messages: [Message]) -> String {
        messages.map { msg in
            let roleLabel: String
            switch msg {
            case .user: roleLabel = "用户"
            case .assistant: roleLabel = "助手"
            case .assistantWithToolCalls: roleLabel = "助手(工具调用)"
            case .toolCall: roleLabel = "工具调用"
            case .toolResult: roleLabel = "工具结果"
            case .system: roleLabel = "系统"
            }
            return "[\(roleLabel)] \(msg.content)"
        }.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Response Parsing

    /// 解析 LLM 返回的 JSON 提取结果
    /// 期望格式：[{"type": "preference", "content": "...", "keywords": ["..."]}]
    private func parseExtractionResponse(_ response: String) -> [ExtractedMemory] {
        // 清理响应文本（去除可能的 markdown 代码块标记）
        var jsonText = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        }
        if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }
        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }
        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonText.data(using: .utf8) else {
            memoryLogger.warning("MemoryExtractor: cannot parse response as JSON")
            return []
        }

        do {
            let items = try JSONDecoder().decode([ExtractedMemory].self, from: data)
            return items
        } catch {
            // 尝试解析单个对象（非数组）
            if let single = try? JSONDecoder().decode(ExtractedMemory.self, from: data) {
                return [single]
            }
            memoryLogger.warning("MemoryExtractor: JSON decode failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Extract Prompt

    /// 记忆提取 prompt — 指导 LLM 从对话中提取 5 类记忆
    static let extractPrompt = """
    你是一个记忆提取助手。你的任务是从编程助手对话历史中提取值得长期记住的信息。

    ## 提取的记忆类型

    1. **preference** — 用户偏好（如编程语言偏好、代码风格、工作习惯）
    2. **decision** — 技术决策（如选择某个框架、采用某种架构）
    3. **todo** — 待办事项（如需要修复的 bug、需要实现的功能）
    4. **fact** — 事实知识（如项目使用的技术栈、文件结构、关键配置）
    5. **workLog** — 工作日志（如已完成的任务、已解决的问题）

    ## 提取原则

    - 只提取对未来工作有价值的信息，忽略寒暄和临时对话
    - 每条记忆应简洁、自包含、可独立理解
    - keywords 应为便于检索的关键词（2-5 个）
    - 如果对话中没有值得提取的信息，返回空数组 []

    ## 输出格式

    输出 JSON 数组，每个元素格式如下：

    ```json
    [
      {
        "type": "preference",
        "content": "用户偏好使用 Swift 5.9 的 Macro 语法",
        "keywords": ["swift", "macro", "偏好"]
      }
    ]
    ```

    type 只能是以下值之一：preference, decision, todo, fact, workLog
    """
}

// MARK: - Extracted Memory (Decodable)

/// LLM 提取的记忆条目 — 用于 JSON 解码
private struct ExtractedMemory: Decodable {
    let type: MemoryType
    let content: String
    let keywords: [String]
}

// MARK: - Memory Extractor Error

private enum MemoryExtractorError: LocalizedError {
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "记忆提取超时（\(Int(BaizeSummary.timeoutSeconds))秒）"
        case .emptyResponse: return "记忆提取返回空响应"
        }
    }
}
