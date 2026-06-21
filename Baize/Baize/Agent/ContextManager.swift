import Foundation

/// 上下文构建器 — 构建 LLM 请求的完整上下文
/// 组合：system prompt + BAIZE.md 扩展 + 对话历史 + 工具定义
/// 负责 Token 预算管理、上下文压缩（LLM 摘要 + 配对感知 + token 预算保留）
///
/// P0 重写：
/// - buildContext 改为 async（compact 需调 LLM 生成摘要）
/// - compact 重写为 async，调 LLM 生成结构化摘要（哨兵前缀标记）
/// - 压缩截断感知 tool_call/tool_result 配对（adjustSplitForPairIntegrity）
/// - 按 token 预算（contextWindow × 30%）从末尾向前累积保留近期消息
/// - 统一 token 估算为 Array<Message>.estimatedTokens（删除私有版本）
struct ContextManager {

    // MARK: - Properties

    /// 项目上下文
    private let projectContext: ProjectContext

    /// Token 预算上限
    private let tokenBudget: Int

    /// API 网关 — 用于调 LLM 生成上下文摘要
    private let apiGateway: APIGateway

    /// R1 新增：Memory 存储 — 用于在 buildSystemPrompt 时注入相关记忆
    /// 通过 init 注入，可为 nil（T01 占位阶段无记忆功能）
    private let memoryStore: MemoryStore?

    // MARK: - Initialization

    /// 创建上下文管理器
    /// - Parameters:
    ///   - projectContext: 项目上下文（BAIZE.md 等）
    ///   - apiGateway: API 网关（用于摘要 LLM 调用）
    ///   - memoryStore: 记忆存储（R1 新增，可选 — nil 时不注入记忆）
    ///   - tokenBudget: Token 预算上限，默认为可用历史 token 数
    init(
        projectContext: ProjectContext,
        apiGateway: APIGateway,
        memoryStore: MemoryStore? = nil,
        tokenBudget: Int = BaizeToken.availableHistoryTokens
    ) {
        self.projectContext = projectContext
        self.apiGateway = apiGateway
        self.memoryStore = memoryStore
        self.tokenBudget = tokenBudget
    }

    // MARK: - Public API

    /// 构建完整的 LLM 请求上下文（P0: 改为 async）
    ///
    /// 流程：
    /// 1. 构建系统提示（R1 新增：注入相关记忆）
    /// 2. 判断是否需要压缩（shouldCompact）
    /// 3. 若需要压缩：调 compact（async，含 LLM 摘要生成）
    /// 4. 构建最终消息列表（system prompt + 压缩后的历史）
    ///
    /// - Parameters:
    ///   - messages: 当前对话消息列表
    ///   - contextWindow: 当前模型的上下文窗口大小
    ///   - userQuery: 用户当前输入（R1 新增 — 用于记忆检索匹配，可选）
    /// - Returns: PromptContext（包含构建好的消息列表 + 压缩元信息 + 注入记忆数）
    func buildContext(messages: [Message], contextWindow: Int = BaizeToken.maxContextTokens, userQuery: String? = nil) async -> PromptContext {
        // 1. 构建系统提示（R1: 注入相关记忆）
        let (systemPrompt, injectedMemoryCount) = await buildSystemPrompt(userQuery: userQuery)

        // 2. 判断是否需要压缩
        var processedMessages = messages
        var didCompact = false
        var compactedHistory: [Message]? = nil
        var summaryText: String? = nil
        var compactionError: String? = nil
        var compactedCount = 0
        var retainedCount = 0

        if shouldCompact(messages: messages, contextWindow: contextWindow) {
            // 3. 执行压缩（async，含 LLM 摘要生成）
            let result = await compact(messages: messages, contextWindow: contextWindow)
            processedMessages = result.compactedHistory
            didCompact = true
            compactedHistory = result.compactedHistory
            summaryText = result.summaryText
            compactionError = result.compactionError
            compactedCount = result.compactedCount
            retainedCount = result.retainedCount
        }

        // 4. 构建最终消息列表（system prompt + 处理后的历史）
        var contextMessages: [Message] = [.system(systemPrompt)]
        contextMessages.append(contentsOf: processedMessages)

        // Bug 1 fix: 安全网 — 修复孤立的 tool_call，防止 API 400 错误
        // （工具执行异常或竞态导致 tool_result 缺失时自动补全占位结果）
        contextMessages = contextMessages.repairingOrphanedToolCalls()

        return PromptContext(
            systemPrompt: systemPrompt,
            messages: contextMessages,
            estimatedTokens: contextMessages.estimatedTokens,
            didCompact: didCompact,
            compactedHistory: compactedHistory,
            summaryText: summaryText,
            compactionError: compactionError,
            compactedCount: compactedCount,
            retainedCount: retainedCount,
            injectedMemoryCount: injectedMemoryCount
        )
    }

    /// 判断是否需要压缩上下文
    /// - Parameters:
    ///   - messages: 当前消息列表
    ///   - contextWindow: 当前模型的上下文窗口大小（默认 BaizeToken.maxContextTokens）
    /// - Returns: 是否超过压缩阈值（(contextWindow - 预留) × compactThresholdRatio - outputReserveTokens）
    func shouldCompact(messages: [Message], contextWindow: Int = BaizeToken.maxContextTokens) -> Bool {
        let estimatedTokens = messages.estimatedTokens
        let availableHistory = contextWindow - BaizeToken.systemPromptReserve - BaizeToken.toolDefinitionsReserve
        let threshold = Int(Double(availableHistory) * BaizeToken.compactThresholdRatio) - BaizeToken.outputReserveTokens
        return estimatedTokens > threshold
    }

    // MARK: - Compaction (P0-2/P0-3/P0-5)

    /// 上下文压缩 — 调 LLM 生成结构化摘要 + 按 token 预算保留近期消息
    ///
    /// 流程：
    /// 1. splitForCompaction → (toSummarize, toRetain) 按 token 预算分割 + 配对修正
    /// 2. generateSummary → 调 LLM 生成摘要（30s 超时降级）
    /// 3. 成功 → [摘要消息] + toRetain；失败 → toRetain（无摘要，降级）
    ///
    /// - Parameters:
    ///   - messages: 当前消息列表
    ///   - contextWindow: 当前模型的上下文窗口大小
    /// - Returns: CompactResult（压缩后历史 + 摘要文本 + 错误信息 + 计数）
    private func compact(messages: [Message], contextWindow: Int) async -> CompactResult {
        // 1. 分割：按 token 预算 + 配对完整性
        let (toSummarize, toRetain) = splitForCompaction(messages: messages, contextWindow: contextWindow)

        // 边界：无待摘要消息 → 直接返回保留区
        guard !toSummarize.isEmpty else {
            agentLogger.info("Context compact: no messages to summarize, retaining \(toRetain.count) messages")
            return CompactResult(
                compactedHistory: toRetain,
                summaryText: nil,
                compactionError: nil,
                compactedCount: 0,
                retainedCount: toRetain.count
            )
        }

        // 2. 调 LLM 生成摘要（含 30s 超时降级）
        do {
            let summaryText = try await generateSummary(messages: toSummarize)
            let summaryMessage = Message.summary(summaryText)
            let compactedHistory: [Message] = [summaryMessage] + toRetain

            agentLogger.info("Context compacted: \(messages.count) → \(compactedHistory.count) messages (summary generated, \(toSummarize.count) summarized, \(toRetain.count) retained)")

            return CompactResult(
                compactedHistory: compactedHistory,
                summaryText: summaryText,
                compactionError: nil,
                compactedCount: toSummarize.count,
                retainedCount: toRetain.count
            )
        } catch {
            // 3. 降级：返回 toRetain（无摘要），记录错误
            agentLogger.warning("Summary generation failed, falling back to retain-only: \(error.localizedDescription)")

            return CompactResult(
                compactedHistory: toRetain,
                summaryText: nil,
                compactionError: error.localizedDescription,
                compactedCount: toSummarize.count,
                retainedCount: toRetain.count
            )
        }
    }

    /// 分割消息列表为待摘要区和保留区（P0-5: token 预算 + P0-3: 配对完整性）
    ///
    /// 算法：
    /// 1. 从末尾向前累积 token，达 retentionBudget（contextWindow × 30%）停止 → 初始 splitIndex
    /// 2. adjustSplitForPairIntegrity 修正 splitIndex，确保 tool_call/tool_result 配对完整
    ///
    /// - Parameters:
    ///   - messages: 当前消息列表
    ///   - contextWindow: 当前模型的上下文窗口大小
    /// - Returns: (summarize: 待摘要消息, retain: 保留消息)
    private func splitForCompaction(messages: [Message], contextWindow: Int) -> (summarize: [Message], retain: [Message]) {
        guard !messages.isEmpty else {
            return (summarize: [], retain: [])
        }

        // 近期保留 token 预算 = contextWindow × 30%（动态 contextWindow）
        let retentionBudget = Int(Double(contextWindow) * BaizeToken.recentRetentionRatio)

        // 从末尾向前累积 token
        var accumulatedTokens = 0
        var splitIndex = messages.count  // 默认：全部在摘要区

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let msgTokens = [messages[i]].estimatedTokens
            if accumulatedTokens + msgTokens > retentionBudget {
                splitIndex = i + 1
                break
            }
            accumulatedTokens += msgTokens
        }

        // 兜底：至少保留最后 1 条消息（即使单条就超预算）
        if splitIndex >= messages.count {
            splitIndex = messages.count - 1
        }

        // P0-3: 配对完整性修正
        splitIndex = adjustSplitForPairIntegrity(messages: messages, initialSplit: splitIndex)

        let summarize = Array(messages[0..<splitIndex])
        let retain = Array(messages[splitIndex...])

        agentLogger.info("Split for compaction: \(summarize.count) to summarize, \(retain.count) to retain, budget=\(retentionBudget), accumulated=\(accumulatedTokens)")

        return (summarize: summarize, retain: retain)
    }

    /// 配对完整性修正 — 确保分割点不破坏 tool_call/tool_result 配对（P0-3）
    ///
    /// 规则（循环直到不变）：
    /// 1. 若 messages[split] 是 .toolResult(id=X)：
    ///    在 messages[0..<split] 中查找对应 tool_call（.assistantWithToolCalls 或 .toolCall）
    ///    若找到 at callIndex：split = callIndex（把 tool_call 拉入保留区）
    /// 2. 若 messages[split-1] 是 .assistantWithToolCalls 或 .toolCall：
    ///    提取其所有 toolCallIds，检查 messages[split...] 中是否有对应 .toolResult
    ///    若有：split -= 1（把 tool_call 拉入保留区，避免孤立）
    ///
    /// - Parameters:
    ///   - messages: 完整消息列表
    ///   - initialSplit: 基于 token 预算的初始分割点
    /// - Returns: 修正后的分割点（只可能 ≤ initialSplit，即保留区只扩大不缩小）
    private func adjustSplitForPairIntegrity(messages: [Message], initialSplit: Int) -> Int {
        var split = initialSplit
        var changed = true

        while changed {
            changed = false

            // 边界保护：split 必须在 (0, messages.count) 范围内
            guard split > 0 && split < messages.count else { break }

            // Case 1: messages[split] 是 .toolResult(id=X)
            // → 在摘要区查找对应 tool_call，若找到则将 split 移至 callIndex
            if case .toolResult(let resultId, _) = messages[split] {
                for i in 0..<split {
                    // 检查 .assistantWithToolCalls 是否包含 id=X
                    if case .assistantWithToolCalls(_, let toolCalls) = messages[i] {
                        if toolCalls.contains(where: { $0.id == resultId }) {
                            split = i
                            changed = true
                            break
                        }
                    }
                    // 检查 .toolCall(id=X)
                    if case .toolCall(let id, _, _) = messages[i] {
                        if id == resultId {
                            split = i
                            changed = true
                            break
                        }
                    }
                }
            }

            if changed { continue }

            // Case 2: messages[split-1] 是 .assistantWithToolCalls 或 .toolCall
            // → 检查保留区是否有对应 .toolResult，若有则 split -= 1
            if split > 0 {
                let prevMessage = messages[split - 1]
                let toolCallIds: [String]

                switch prevMessage {
                case .assistantWithToolCalls(_, let toolCalls):
                    toolCallIds = toolCalls.map(\.id)
                case .toolCall(let id, _, _):
                    toolCallIds = [id]
                default:
                    toolCallIds = []
                }

                if !toolCallIds.isEmpty {
                    // 检查保留区 messages[split...] 是否有对应 .toolResult
                    for i in split..<messages.count {
                        if case .toolResult(let resultId, _) = messages[i] {
                            if toolCallIds.contains(resultId) {
                                split -= 1
                                changed = true
                                break
                            }
                        }
                    }
                }
            }
        }

        return max(split, 0)
    }

    /// 调 LLM 生成结构化摘要（P0-2）
    ///
    /// 流程：
    /// 1. formatMessagesForSummary → 文本拼接（避免 tool_call/tool_result API 校验问题）
    /// 2. 构建摘要请求 [.system(摘要prompt), .user(格式化文本)]
    /// 3. apiGateway.streamComplete(tools:[]) → 消费流收集文本
    /// 4. TaskGroup 30s 超时 + 空响应检查
    ///
    /// - Parameter messages: 待摘要的消息列表
    /// - Returns: LLM 生成的摘要文本
    /// - Throws: SummaryError.timeout / .emptyResponse / 其他 LLM 错误
    private func generateSummary(messages: [Message]) async throws -> String {
        // 1. 格式化消息为文本
        let textBlob = formatMessagesForSummary(messages)

        // 2. 构建摘要请求（文本拼接，避免 API 格式校验问题）
        let summaryRequest: [Message] = [
            .system(BaizeSummary.systemPrompt),
            .user(textBlob)
        ]

        // 3. TaskGroup：摘要生成 vs 30s 超时
        return try await withThrowingTaskGroup(of: String.self) { group in
            // 摘要生成任务
            group.addTask { [apiGateway] in
                var summary = ""
                let stream = await apiGateway.streamComplete(messages: summaryRequest, tools: [])
                for try await chunk in stream {
                    if case .textDelta(let text) = chunk {
                        summary += text
                    }
                }
                // 空响应检查
                if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw SummaryError.emptyResponse
                }
                return summary
            }

            // 超时任务
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(BaizeSummary.timeoutSeconds * 1_000_000_000))
                throw SummaryError.timeout
            }

            // 等待第一个任务完成（成功或超时）
            let result = try await group.next() ?? ""
            // 取消剩余任务
            group.cancelAll()
            return result
        }
    }

    /// 格式化消息列表为摘要请求文本（P0-2 共享知识 §8.5）
    ///
    /// 将 Message 数组格式化为 `[角色] 内容` 纯文本拼接，
    /// 避免 tool_call/tool_result 在摘要请求中触发 API 校验。
    ///
    /// - Parameter messages: 待格式化的消息列表
    /// - Returns: 格式化后的文本（消息间用分隔线连接）
    private func formatMessagesForSummary(_ messages: [Message]) -> String {
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

    // MARK: - Private Methods

    /// 构建系统提示 — 定义 Agent 的角色和行为规范
    /// R1 新增：注入相关记忆（从 MemoryStore 检索）
    /// - Parameter userQuery: 用户当前输入（用于记忆检索匹配，可选）
    /// - Returns: (系统提示文本, 注入记忆条数)
    private func buildSystemPrompt(userQuery: String?) async -> (String, Int) {
        var prompt = """
        你是白泽（Baize），一个运行在 iOS iPad 上的本地编程智能体。

        你可以：
        - 读写和编辑本地文件系统中的文件
        - 执行 Shell 命令（通过 ios_system）
        - 运行 Node.js 和 Python 脚本
        - 搜索文件和代码内容

        你应该：
        - 先观察项目结构，再做出决策
        - 每次只做一步操作，等待结果后再决定下一步
        - 对危险操作（文件删除、系统命令）格外谨慎
        - 遵循项目的编码规范和配置

        """

        // 添加 BAIZE.md 扩展
        let baizeExtension = projectContext.systemPromptExtension
        if !baizeExtension.isEmpty {
            prompt += "\n项目配置 (BAIZE.md):\n" + baizeExtension
        }

        // R1 新增：注入相关记忆
        var injectedMemoryCount = 0
        if let store = memoryStore, let query = userQuery, !query.isEmpty {
            let memories = await store.findRelevantMemories(
                query: query,
                limit: BaizeToken.memoryInjectionLimit
            )

            if !memories.isEmpty {
                injectedMemoryCount = memories.count
                let memoryText = memories.map { memory in
                    "- [\(memory.type.rawValue)] \(memory.content)"
                }.joined(separator: "\n")
                prompt += "\n\n相关记忆:\n" + memoryText
            }
        }

        prompt += "\n\n请基于以上信息，为用户提供编程帮助。"

        return (prompt, injectedMemoryCount)
    }
}

// MARK: - Compact Result (Private)

/// 压缩结果 — compact 方法的返回类型
private struct CompactResult {
    /// 压缩后的完整消息历史（摘要消息 + 保留消息，或仅保留消息）
    let compactedHistory: [Message]
    /// LLM 生成的摘要文本（降级时为 nil）
    let summaryText: String?
    /// 压缩错误描述（降级时非 nil）
    let compactionError: String?
    /// 被压缩（摘要）的消息条数
    let compactedCount: Int
    /// 保留的近期消息条数
    let retainedCount: Int
}

// MARK: - Summary Error (Private)

/// 摘要生成错误类型
private enum SummaryError: LocalizedError {
    /// 30s 超时
    case timeout
    /// LLM 返回空响应
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "摘要生成超时（\(Int(BaizeSummary.timeoutSeconds))秒）"
        case .emptyResponse: return "摘要生成返回空响应"
        }
    }
}

// MARK: - Prompt Context

/// LLM 请求上下文 — 构建好的消息列表 + 估算 Token 数 + 压缩元信息
struct PromptContext {
    /// 系统提示文本
    let systemPrompt: String
    /// 完整消息列表（含 system prompt + 压缩后的历史）
    let messages: [Message]
    /// 估算 Token 总数
    let estimatedTokens: Int

    // MARK: - Compaction Metadata (P0-2)

    /// 是否执行了压缩
    let didCompact: Bool
    /// 压缩后的消息历史（AgentLoop 写回 session.messages 防止重复压缩）
    let compactedHistory: [Message]?
    /// LLM 生成的摘要文本（降级时为 nil）
    let summaryText: String?
    /// 压缩错误描述（降级时非 nil）
    let compactionError: String?
    /// 被压缩（摘要）的消息条数
    let compactedCount: Int
    /// 保留的近期消息条数
    let retainedCount: Int

    /// R1 新增：注入的记忆条数（用于发射 .memoryInjected(count:) 事件）
    let injectedMemoryCount: Int

    /// 创建 PromptContext
    init(
        systemPrompt: String,
        messages: [Message],
        estimatedTokens: Int,
        didCompact: Bool = false,
        compactedHistory: [Message]? = nil,
        summaryText: String? = nil,
        compactionError: String? = nil,
        compactedCount: Int = 0,
        retainedCount: Int = 0,
        injectedMemoryCount: Int = 0
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.estimatedTokens = estimatedTokens
        self.didCompact = didCompact
        self.compactedHistory = compactedHistory
        self.summaryText = summaryText
        self.compactionError = compactionError
        self.compactedCount = compactedCount
        self.retainedCount = retainedCount
        self.injectedMemoryCount = injectedMemoryCount
    }
}
