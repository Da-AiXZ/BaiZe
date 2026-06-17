import Foundation

/// 上下文构建器 — 构建 LLM 请求的完整上下文
/// 组合：system prompt + BAIZE.md 扩展 + 对话历史 + 工具定义
/// 负责 Token 预算管理、上下文压缩（Snip 策略）
struct ContextManager {

    // MARK: - Properties

    /// 项目上下文
    private let projectContext: ProjectContext

    /// Token 预算上限
    private let tokenBudget: Int

    // MARK: - Initialization

    init(
        projectContext: ProjectContext,
        tokenBudget: Int = BaizeToken.availableHistoryTokens
    ) {
        self.projectContext = projectContext
        self.tokenBudget = tokenBudget
    }

    // MARK: - Public API

    /// 构建完整的 LLM 请求上下文
    /// - Parameter messages: 当前对话消息列表
    /// - Returns: PromptContext（包含构建好的消息列表）
    func buildContext(messages: [Message]) -> PromptContext {
        // 1. 构建系统提示
        let systemPrompt = buildSystemPrompt()

        // 2. 判断是否需要压缩
        var processedMessages = messages
        if shouldCompact(messages: messages) {
            processedMessages = compact(messages: messages)
        }

        // 3. 构建最终消息列表（system prompt + 压缩后的历史）
        var contextMessages: [Message] = [.system(systemPrompt)]
        contextMessages.append(contentsOf: processedMessages)

        return PromptContext(
            systemPrompt: systemPrompt,
            messages: contextMessages,
            estimatedTokens: estimateTokens(messages: contextMessages)
        )
    }

    /// 判断是否需要压缩上下文
    /// - Parameter messages: 当前消息列表
    /// - Returns: 是否超过压缩阈值
    func shouldCompact(messages: [Message]) -> Bool {
        let estimatedTokens = estimateTokens(messages: messages)
        let threshold = Int(Double(tokenBudget) * BaizeToken.compactThresholdRatio)
        return estimatedTokens > threshold
    }

    /// Snip 压缩策略 — 移除最旧的历史消息，保留最近的对话
    /// Phase 1: 简单 Snip（移除旧消息），Phase 2: 5 层压缩
    /// - Parameter messages: 当前消息列表
    /// - Returns: 压缩后的消息列表
    func compact(messages: [Message]) -> [Message] {
        guard messages.count > 4 else { return messages }

        // 保留最后 4 条消息（最近的对话上下文最重要）
        let recentMessages = messages.suffix(4)

        // 添加摘要占位（告诉 LLM 之前的对话已被压缩）
        let summaryMessage = Message.user(
            "[系统提示: 之前的 \(messages.count - recentMessages.count) 条对话已被压缩。" +
            "以下是最近的对话内容，请继续基于此上下文回应。]"
        )

        var compacted: [Message] = [summaryMessage]
        compacted.append(contentsOf: recentMessages)

        agentLogger.info("Context compacted: \(messages.count) → \(compacted.count) messages")
        return compacted
    }

    // MARK: - Private Methods

    /// 构建系统提示 — 定义 Agent 的角色和行为规范
    private func buildSystemPrompt() -> String {
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

        prompt += "\n\n请基于以上信息，为用户提供编程帮助。"

        return prompt
    }

    /// 估算消息列表的 Token 总数
    /// 简单启发式：字符数 × 0.25 ≈ Token 数
    private func estimateTokens(messages: [Message]) -> Int {
        messages.reduce(0) { sum, msg in sum + msg.content.estimatedTokens }
    }
}

// MARK: - Prompt Context

/// LLM 请求上下文 — 构建好的消息列表 + 估算 Token 数
struct PromptContext {
    let systemPrompt: String
    let messages: [Message]
    let estimatedTokens: Int
}