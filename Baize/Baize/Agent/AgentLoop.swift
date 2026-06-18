import Foundation

/// Agent 核心循环 — Actor 并发模型
/// 实现 while-true 循环：用户消息 → LLM 推理 → tool_call → 执行 → 结果注入 → 继续循环
/// 参考 Claude Code 单循环架构：让 LLM 自主决定下一步
/// 通过 AsyncThrowingStream<AgentEvent> 向 UI 推送每一步的状态变化
actor AgentLoop {

    // MARK: - Dependencies

    private let apiGateway: APIGateway
    private let toolRegistry: ToolRegistry
    private let permissionEngine: PermissionEngine
    private let contextManager: ContextManager
    private let conversationStore: ConversationStore

    /// W22 fix: 注入共享的 FileSystemService 和 RuntimeExecutor，
    /// 避免在 ToolExecutionContext 中创建独立实例
    private let fileSystemService: FileSystemService
    private let runtimeExecutor: RuntimeExecutor

    // MARK: - State

    /// 当前对话会话
    private var session: ConversationSession

    /// 是否正在运行 Agent Loop
    private var isRunning: Bool = false

    /// 用户确认的挂起 continuation — .ask 决策时挂起等待用户确认
    private var pendingContinuation: CheckedContinuation<Bool, Never>?

    /// 标记是否已被取消（用于处理 cancellation 与 setPendingContinuation 的竞态）
    private var isCancelled: Bool = false

    // MARK: - Initialization

    init(
        apiGateway: APIGateway,
        toolRegistry: ToolRegistry,
        permissionEngine: PermissionEngine,
        contextManager: ContextManager,
        conversationStore: ConversationStore,
        fileSystemService: FileSystemService,
        runtimeExecutor: RuntimeExecutor,
        session: ConversationSession = ConversationSession()
    ) {
        self.apiGateway = apiGateway
        self.toolRegistry = toolRegistry
        self.permissionEngine = permissionEngine
        self.contextManager = contextManager
        self.conversationStore = conversationStore
        self.fileSystemService = fileSystemService
        self.runtimeExecutor = runtimeExecutor
        self.session = session
    }

    // MARK: - Public API

    /// 启动 Agent Loop — 处理用户消息，返回事件流
    /// - Parameter userMessage: 用户输入文本
    /// - Returns: AsyncThrowingStream<AgentEvent> 供 UI 消费
    func run(userMessage: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // W19 fix: 使用 isFinished 标志防止 continuation.finish() 被重复调用
                var isFinished = false
                let safeFinish: (Error?) -> Void = { error in
                    guard !isFinished else { return }
                    isFinished = true
                    if let error = error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }

                do {
                    isCancelled = false
                    isRunning = true
                    agentLogger.info("Agent Loop started: processing user message")

                    // 1. 添加用户消息
                    session.messages.append(.user(userMessage))

                    // 2. 进入 Agent 循环
                    try await agentLoop(continuation: continuation)

                    // 3. 循环结束，保存对话
                    session.updatedAt = Date()
                    try await conversationStore.save(session: session)

                    // 4. 发送完成事件
                    continuation.yield(.completed)
                    agentLogger.info("Agent Loop completed")
                } catch {
                    agentLogger.error("Agent Loop error: \(error.localizedDescription)")
                    continuation.yield(.error(error))
                }

                isRunning = false
                // W19 fix: 使用 safeFinish 确保 finish() 只被调用一次
                safeFinish(nil)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 获取当前对话会话
    func getCurrentSession() -> ConversationSession {
        session
    }

    /// 更新对话会话
    func updateSession(_ newSession: ConversationSession) {
        session = newSession
    }

    /// 停止 Agent Loop
    func stop() {
        isRunning = false
        isCancelled = true
        // 清理挂起的确认 continuation，防止泄漏和悬挂
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(returning: false)
        }
        agentLogger.info("Agent Loop stopped by user")
    }

    // MARK: - Core Loop

    /// Agent 核心循环：LLM 推理 → 工具调用 → 执行 → 结果注入 → 继续或结束
    private func agentLoop(continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        // 安全限制：最大循环次数防止无限循环
        let maxIterations = 50
        let maxConsecutiveFailures = 3
        var iterationCount = 0
        var consecutiveFailures = 0

        while isRunning && iterationCount < maxIterations {
            iterationCount += 1
            agentLogger.info("Agent Loop iteration \(iterationCount), consecutive failures: \(consecutiveFailures)")

            // 1. 构建上下文（系统提示 + BAIZE.md + 对话历史 + 工具定义）
            let promptContext = contextManager.buildContext(messages: session.messages)
            let toolDefinitions = await toolRegistry.getToolDefinitions()

            // 2. 调用 LLM API（SSE 流式）
            // 修复 C3：使用 promptContext.messages（含 system prompt + BAIZE.md + 压缩历史）
            // 而非原始 session.messages
            let llmStream = await apiGateway.streamComplete(
                messages: promptContext.messages,
                tools: toolDefinitions
            )

            // 3. 消费 LLM 响应流
            var accumulatedText = ""
            var accumulatedToolCalls: [ToolCall] = []
            var currentToolCallArguments: [String: String] = [:] // id → arguments
            var toolCallNames: [String: String] = [:] // id → name（从 toolCallBegin 事件收集）

            for try await chunk in llmStream {
                switch chunk {
                case .textDelta(let text):
                    accumulatedText += text
                    continuation.yield(.textDelta(text))

                case .toolCallBegin(id: let id, name: let name):
                    currentToolCallArguments[id] = ""
                    toolCallNames[id] = name  // ✅ 正确收集工具名称
                    let toolCall = ToolCall(id: id, name: name, arguments: "")
                    accumulatedToolCalls.append(toolCall)  // 保存 begin 事件中的 ToolCall
                    continuation.yield(.toolCall(toolCall))

                case .toolCallDelta(id: let id, argumentsDelta: let delta):
                    if let current = currentToolCallArguments[id] {
                        currentToolCallArguments[id] = current + delta
                    }

                case .done(finishReason: let reason):
                    agentLogger.info("LLM stream done, finish reason: \(reason)")
                }
            }

            // 4. 构建完整的 ToolCall 对象（将累积的 arguments 更新到已有的 ToolCall 上）
            // 使用 toolCallNames 字典获取正确的工具名称
            var completedToolCalls: [ToolCall] = []
            for (id, arguments) in currentToolCallArguments {
                let name = toolCallNames[id] ?? "unknown"
                completedToolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
            }

            // 5. 处理 LLM 响应 — 修复 C1/C2：assistant 文本和 tool_calls 合并为单条消息
            if !currentToolCallArguments.isEmpty {
                // 有 tool_calls：构建 assistantWithToolCalls 消息
                let completedCalls: [ToolCall] = currentToolCallArguments.map { (id, arguments) in
                    let name = toolCallNames[id] ?? "unknown"
                    return ToolCall(id: id, name: name, arguments: arguments)
                }
                // 无论是否有文本，tool_calls 必须与文本合并在同一个 assistant 消息中
                session.messages.append(.assistantWithToolCalls(content: accumulatedText, toolCalls: completedCalls))
            } else if !accumulatedText.isEmpty {
                // 只有文本，无 tool_calls
                session.messages.append(.assistant(accumulatedText))
            }

            // 6. 如果有 tool_calls，执行它们
            if !currentToolCallArguments.isEmpty {
                // 构建 assistant 消息（包含 tool_calls）
                // OpenAI 格式要求 assistant 消息与 tool_result 消息配对

                // 执行每个 tool_call
                for (id, arguments) in currentToolCallArguments {
                    let name = toolCallNames[id] ?? "unknown"
                    let toolCall = ToolCall(id: id, name: name, arguments: arguments)

                    // 诊断：记录工具调用的原始参数
                    agentLogger.info("Executing tool: \(name), id=\(id), arguments='\(arguments)'")

                    // 注意：不再添加 .toolCall 消息到历史
                    // tool_call 信息已包含在 .assistantWithToolCalls 消息中（修复 C1/C2）

                    // 权限检查
                    // W22 fix: 使用注入的共享服务，而非创建新实例
                    let executionContext = ToolExecutionContext(
                        projectPath: session.projectPath,
                        fileSystemService: fileSystemService,
                        runtimeExecutor: runtimeExecutor,
                        permissionEngine: permissionEngine
                    )

                    // W4 fix: PermissionEngine 改为 actor，evaluate 需要 await
                    let decision = await permissionEngine.evaluate(
                        toolCall: toolCall,
                        context: executionContext
                    )

                    switch decision.effect {
                    case .allow:
                        // 执行工具
                        continuation.yield(.toolExecuting(toolCall))
                        let result = await toolRegistry.execute(toolCall: toolCall, context: executionContext)
                        continuation.yield(.toolResult(toolCall, result))

                        // 将结果注入对话历史
                        session.messages.append(.toolResult(id: id, content: result.toToolResultContent()))

                        // 失败计数：如果工具执行返回错误，增加连续失败计数
                        if result.isError {
                            consecutiveFailures += 1
                            agentLogger.warning("Tool \(name) failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(result.toToolResultContent())")
                        } else {
                            consecutiveFailures = 0
                        }

                    case .ask:
                        // 需要用户确认 — 挂起等待用户在 UI 上确认
                        continuation.yield(.askConfirmation(toolCall, decision.reason))
                        let allowed = await withTaskCancellationHandler {
                            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                                Task { await self.setPendingContinuation(cont) }
                            }
                        } onCancel: {
                            // Task 被取消时恢复挂起的 continuation，防止泄漏
                            Task { await self.cancelPendingConfirmation() }
                        }
                        if allowed {
                            // 用户允许 — 执行工具（与 .allow 路径一致）
                            continuation.yield(.toolExecuting(toolCall))
                            let result = await toolRegistry.execute(toolCall: toolCall, context: executionContext)
                            continuation.yield(.toolResult(toolCall, result))
                            session.messages.append(.toolResult(id: id, content: result.toToolResultContent()))
                            if result.isError {
                                consecutiveFailures += 1
                                agentLogger.warning("Tool \(name) failed (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(result.toToolResultContent())")
                            } else {
                                consecutiveFailures = 0
                            }
                        } else {
                            // 用户拒绝
                            let deniedResult = ToolResult.denied(reason: decision.reason)
                            continuation.yield(.denied(toolCall, decision.reason))
                            session.messages.append(.toolResult(id: id, content: deniedResult.toToolResultContent()))
                            consecutiveFailures += 1
                        }

                    case .deny:
                        // 直接拒绝
                        let deniedResult = ToolResult.denied(reason: decision.reason)
                        continuation.yield(.denied(toolCall, decision.reason))
                        session.messages.append(.toolResult(id: id, content: deniedResult.toToolResultContent()))
                        consecutiveFailures += 1
                    }
                }

                // 连续失败检查：超过阈值则停止循环
                if consecutiveFailures >= maxConsecutiveFailures {
                    agentLogger.error("Agent Loop: \(consecutiveFailures) consecutive failures, stopping")
                    continuation.yield(.textDelta("\n\n[系统提示：连续 \(consecutiveFailures) 次工具调用失败，Agent 循环已停止。请检查工具参数是否正确。]"))
                    break
                }

                // 继续循环（工具结果注入后，LLM 需要继续推理）
                agentLogger.info("Tool calls processed, continuing loop")
                continue
            }

            // 7. 无 tool_calls — LLM 只返回了文本，循环结束
            agentLogger.info("No tool calls, Agent Loop ending after \(iterationCount) iterations")
            break
        }

        if iterationCount >= maxIterations {
            agentLogger.warning("Agent Loop hit max iterations limit (\(maxIterations))")
        }
    }

    // MARK: - User Confirmation (for .ask decisions)

    /// 用户确认工具调用 — 在 UI 层调用
    /// 恢复挂起的 continuation，传入用户的确认结果
    /// 工具的实际执行在 agentLoop 的 .ask 分支内完成（唤醒后执行）
    /// - Parameters:
    ///   - toolCall: 需确认的工具调用（用于日志验证）
    ///   - allowed: 用户是否允许
    func confirmToolCall(toolCall: ToolCall, allowed: Bool) async {
        guard let cont = pendingContinuation else {
            agentLogger.warning("confirmToolCall called but no pending continuation (tool: \(toolCall.name))")
            return
        }
        pendingContinuation = nil
        cont.resume(returning: allowed)
    }

    /// 设置挂起的 continuation — 由 withCheckedContinuation 内部调用
    /// 通过独立 actor 方法确保 actor isolation 正确
    /// 如果 task 已被取消（竞态：onCancel 先于 setPendingContinuation 执行），立即 resume
    private func setPendingContinuation(_ cont: CheckedContinuation<Bool, Never>) {
        if isCancelled {
            cont.resume(returning: false)
        } else {
            self.pendingContinuation = cont
        }
    }

    /// 取消挂起的确认 — 由 withTaskCancellationHandler 的 onCancel 调用
    /// 处理两种情况：
    /// 1. pendingContinuation 已设置 → 直接 resume(returning: false)
    /// 2. pendingContinuation 尚未设置（竞态）→ 设置 isCancelled 标志，
    ///    setPendingContinuation 检测到后立即 resume
    private func cancelPendingConfirmation() {
        isCancelled = true
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(returning: false)
        }
    }
}