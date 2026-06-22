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

    /// R1 新增：新工具所需的服务（可选，现有调用点零改动）
    private let skillRegistry: SkillRegistry?
    private let memoryStore: MemoryStore?
    private let commandRegistry: CommandRegistry?
    private let planModeState: PlanModeState?
    private let webSearchProvider: WebSearchProvider?

    /// R2 新增：Sub-agent + MCP 服务（可选，现有调用点零改动）
    private let taskList: TaskList?
    private let teamCoordinator: TeamCoordinator?
    private let mcpManager: MCPManager?

    /// R3 新增：GitService — 供 ExecuteCommandTool 拦截 git 命令转给 libgit2
    private let gitService: GitService?

    // MARK: - State

    /// 当前对话会话
    private var session: ConversationSession

    /// 当前模型的 contextWindow（P1-3 动态预算，由 ChatView 更新）
    private var contextWindow: Int = BaizeToken.maxContextTokens

    /// T05: 每次 query loop 结束时触发的 stop hooks（如 memory extraction）
    private var stopHooks: [(@Sendable () async -> Void)] = []

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
        skillRegistry: SkillRegistry? = nil,
        memoryStore: MemoryStore? = nil,
        commandRegistry: CommandRegistry? = nil,
        planModeState: PlanModeState? = nil,
        webSearchProvider: WebSearchProvider? = nil,
        taskList: TaskList? = nil,
        teamCoordinator: TeamCoordinator? = nil,
        mcpManager: MCPManager? = nil,
        gitService: GitService? = nil,
        session: ConversationSession = ConversationSession()
    ) {
        self.apiGateway = apiGateway
        self.toolRegistry = toolRegistry
        self.permissionEngine = permissionEngine
        self.contextManager = contextManager
        self.conversationStore = conversationStore
        self.fileSystemService = fileSystemService
        self.runtimeExecutor = runtimeExecutor
        self.skillRegistry = skillRegistry
        self.memoryStore = memoryStore
        self.commandRegistry = commandRegistry
        self.planModeState = planModeState
        self.webSearchProvider = webSearchProvider
        self.taskList = taskList
        self.teamCoordinator = teamCoordinator
        self.mcpManager = mcpManager
        self.gitService = gitService
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
                    try await agentLoop(continuation: continuation, userQuery: userMessage)

                    // 3. 循环结束，保存对话
                    session.updatedAt = Date()
                    try await conversationStore.save(session: session)

                    // Bug 1 fix: 循环结束后补一次 contextUsage 发射（最终用量）
                    continuation.yield(.contextUsage(
                        estimatedTokens: session.messages.estimatedTokens,
                        contextWindow: self.contextWindow
                    ))

                    // R1: 会话结束后自动提取记忆（异步，不阻塞 .completed 事件）
                    // 使用 detached task 确保记忆提取不阻塞 UI 完成
                    Task.detached { [weak self] in
                        await self?.extractMemories()
                    }

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

    /// 更新 contextWindow（切换模型或会话恢复时由 ChatView 调用）
    func updateContextWindow(_ window: Int) {
        self.contextWindow = window
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
    private func agentLoop(continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, userQuery: String? = nil) async throws {
        // 安全限制：最大循环次数防止无限循环
        let maxIterations = 50
        let maxConsecutiveFailures = 3
        var iterationCount = 0
        var consecutiveFailures = 0

        // Bug 1 fix: contextUsage 事件节流状态 — 用量变化超过 1% 或每 5 次迭代才发射
        var lastEmittedTokens: Int = 0
        var contextUsageEmitCount: Int = 0

        while isRunning && iterationCount < maxIterations {
            iterationCount += 1
            agentLogger.info("Agent Loop iteration \(iterationCount), consecutive failures: \(consecutiveFailures)")

            // 1. 构建上下文（系统提示 + BAIZE.md + 对话历史 + 工具定义）
            // P0-2: 压缩前发射事件，让 UI 显示"正在压缩"
            if contextManager.shouldCompact(messages: session.messages, contextWindow: contextWindow) {
                continuation.yield(.contextCompacting)
            }

            // P0-2: buildContext 改为 async（compact 需调 LLM 生成摘要）
            let promptContext = await contextManager.buildContext(messages: session.messages, contextWindow: contextWindow, userQuery: userQuery)

            // R1 新增：发射记忆注入事件（如果注入了记忆）
            if promptContext.injectedMemoryCount > 0 {
                continuation.yield(.memoryInjected(count: promptContext.injectedMemoryCount))
            }

            // P0-2: 压缩后写回 session.messages，防止下轮迭代重复压缩（关键！）
            if let compacted = promptContext.compactedHistory {
                session.messages = compacted
                agentLogger.info("Session messages updated after compaction: \(compacted.count) messages")
            }

            // P0-2: 发射压缩完成/失败事件
            if promptContext.didCompact {
                if let summary = promptContext.summaryText {
                    continuation.yield(.contextCompacted(
                        summary: summary,
                        compactedCount: promptContext.compactedCount,
                        retainedCount: promptContext.retainedCount
                    ))
                } else if let error = promptContext.compactionError {
                    continuation.yield(.contextCompactionFailed(error: error))
                }
            }

            // P2-5: 发射上下文用量事件（压缩完成后发射，session.messages 已更新为最新）
            // Bug 1 fix: 节流 — 第 1 次迭代强制发射（用户发消息立即看到初始用量），
            // 后续用量变化超过 1%（最少 200 tokens）或每 5 次迭代才发射
            contextUsageEmitCount += 1
            let currentTokens = session.messages.estimatedTokens
            let tokenDelta = abs(currentTokens - lastEmittedTokens)
            let usageThreshold = max(Int(Double(contextWindow) * 0.01), 200)
            if iterationCount == 1 || tokenDelta >= usageThreshold || contextUsageEmitCount >= 5 {
                continuation.yield(.contextUsage(
                    estimatedTokens: currentTokens,
                    contextWindow: self.contextWindow
                ))
                lastEmittedTokens = currentTokens
                contextUsageEmitCount = 0
            }

            // Phase 1: 计算有效权限模式
            // PlanMode 状态机（用户通过 enter_plan_mode 进入规划阶段）是独立安全层
            // 当 PlanModeState 处于 planning/awaitingApproval 时，对 LLM 只暴露 readOnly 工具
            let currentPermissionMode = await permissionEngine.getMode()
            let isPlanModeActive = await planModeState?.isInPlanMode() ?? false
            let effectiveMode = isPlanModeActive ? PermissionMode.plan : currentPermissionMode

            let toolDefinitions = await toolRegistry.getToolDefinitions(mode: effectiveMode)

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

                case .usage:
                    // T04: usage chunk 由 APIGateway 包装层拦截记录到 UsageTracker，不转发给 AgentLoop
                    // 此 case 仅为满足 Swift enum switch exhaustive 要求，正常运行不会到达
                    break
                }
            }

            // 4. 处理 LLM 响应 — 修复 C1/C2：assistant 文本和 tool_calls 合并为单条消息
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

            // 5. 如果有 tool_calls，执行它们
            if !currentToolCallArguments.isEmpty {
                // Bug 3 fix: 用户拒绝权限时中断 Agent 循环
                var userDeniedTool = false
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
                    // R1: 注入新工具所需的服务
                    let executionContext = ToolExecutionContext(
                        projectPath: session.projectPath,
                        fileSystemService: fileSystemService,
                        runtimeExecutor: runtimeExecutor,
                        permissionEngine: permissionEngine,
                        apiGateway: apiGateway,
                        memoryStore: memoryStore,
                        skillRegistry: skillRegistry,
                        taskList: taskList,
                        planModeState: planModeState,
                        webSearchProvider: webSearchProvider,
                        commandRegistry: commandRegistry,
                        teamCoordinator: teamCoordinator,
                        mcpManager: mcpManager,
                        toolRegistry: toolRegistry,
                        gitService: gitService
                    )

                    // W4 fix: PermissionEngine 改为 actor，evaluate 需要 await
                    let decision = await permissionEngine.evaluate(
                        toolCall: toolCall,
                        context: executionContext
                    )

                    switch decision.effect {
                    case .allow:
                        // Phase 1: PlanMode 写操作拦截已统一移至 PermissionEngine.evaluate
                        // AgentLoop 只根据 PermissionDecision 执行，不再做独立 PlanMode 判断

                        // P0-3 fix: 在执行 exit_plan_mode 工具之前，先发射 .planApprovalRequested 事件
                        // 这样 UI 能收到事件弹出 PlanApprovalView sheet，用户审批后 continuation 恢复
                        if name == "exit_plan_mode" {
                            let plan = toolCall.argumentString(for: "plan") ?? ""
                            continuation.yield(.planApprovalRequested(plan: plan))
                        }

                        // 执行工具
                        continuation.yield(.toolExecuting(toolCall))

                        // 终端事件：execute_command 命令开始执行
                        if name == "execute_command" {
                            let cmd = toolCall.argumentString(for: "command") ?? "(参数缺失)"
                            continuation.yield(.commandExecuting(command: cmd, source: .agent))
                        }

                        let result = await toolRegistry.execute(toolCall: toolCall, context: executionContext)

                        // 终端事件：execute_command 命令输出完成
                        if name == "execute_command" {
                            let cmd = toolCall.argumentString(for: "command") ?? "(参数缺失)"
                            let exitCode = Int(result.metadata["exitCode"] ?? "0") ?? 0
                            continuation.yield(.commandOutput(
                                command: cmd,
                                output: result.output,
                                source: .agent,
                                exitCode: exitCode
                            ))
                        }

                        continuation.yield(.toolResult(toolCall, result))

                        // R1: 特殊工具事件发射
                        emitSpecialToolEvents(name: name, result: result, continuation: continuation)

                        // 将结果注入对话历史（P2-1: 分层截断）
                        // Bug 1 fix: tool_result 必须在所有代码路径都注入，防止 API 400
                        let rawContent = result.toToolResultContent()
                        let truncatedContent = ToolResultTruncator.truncate(toolName: name, output: rawContent)
                        session.messages.append(.toolResult(id: id, content: truncatedContent))

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
                            // Phase 1: PlanMode 写操作拦截已统一移至 PermissionEngine.evaluate
                            // PlanMode 下写工具会被直接 deny，不会进入 .ask 分支，因此无需二次判断

                            // 用户允许 — 执行工具（与 .allow 路径一致）
                            // P0-3 fix: 在执行 exit_plan_mode 工具之前，先发射 .planApprovalRequested 事件
                            if name == "exit_plan_mode" {
                                let plan = toolCall.argumentString(for: "plan") ?? ""
                                continuation.yield(.planApprovalRequested(plan: plan))
                            }

                            continuation.yield(.toolExecuting(toolCall))

                            // 终端事件：execute_command 命令开始执行
                            if name == "execute_command" {
                                let cmd = toolCall.argumentString(for: "command") ?? "(参数缺失)"
                                continuation.yield(.commandExecuting(command: cmd, source: .agent))
                            }

                            let result = await toolRegistry.execute(toolCall: toolCall, context: executionContext)

                            // 终端事件：execute_command 命令输出完成
                            if name == "execute_command" {
                                let cmd = toolCall.argumentString(for: "command") ?? "(参数缺失)"
                                let exitCode = Int(result.metadata["exitCode"] ?? "0") ?? 0
                                continuation.yield(.commandOutput(
                                    command: cmd,
                                    output: result.output,
                                    source: .agent,
                                    exitCode: exitCode
                                ))
                            }

                            continuation.yield(.toolResult(toolCall, result))
                            // R1: 特殊工具事件发射
                            emitSpecialToolEvents(name: name, result: result, continuation: continuation)
                            // P2-1: 分层截断后注入对话历史
                            // Bug 1 fix: tool_result 必须在所有代码路径都注入，防止 API 400
                            let rawContent = result.toToolResultContent()
                            let truncatedContent = ToolResultTruncator.truncate(toolName: name, output: rawContent)
                            session.messages.append(.toolResult(id: id, content: truncatedContent))
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
                            // Bug 3 fix: 用户拒绝权限 → 标记中断
                            userDeniedTool = true
                            break
                        }

                    case .deny:
                        // 直接拒绝
                        let deniedResult = ToolResult.denied(reason: decision.reason)
                        continuation.yield(.denied(toolCall, decision.reason))
                        session.messages.append(.toolResult(id: id, content: deniedResult.toToolResultContent()))
                        consecutiveFailures += 1
                        // Bug 3 fix: 权限被拒 → 标记中断
                        userDeniedTool = true
                        break
                    }
                }

                // Bug 3 fix: 用户拒绝权限 → 中断 Agent 循环（不再让 LLM 换工具尝试）
                if userDeniedTool {
                    agentLogger.info("User denied tool call, stopping Agent Loop")
                    continuation.yield(.textDelta("\n\n[用户拒绝了工具调用，Agent 已停止。]"))
                    break
                }

                // 连续失败检查：超过阈值则停止循环
                if consecutiveFailures >= maxConsecutiveFailures {
                    agentLogger.error("Agent Loop: \(consecutiveFailures) consecutive failures, stopping")
                    continuation.yield(.textDelta("\n\n[系统提示：连续 \(consecutiveFailures) 次工具调用失败，Agent 循环已停止。请检查工具参数是否正确。]"))
                    break
                }

                // 继续循环（工具结果注入后，LLM 需要继续推理）
                agentLogger.info("Tool calls processed, continuing loop")
                await runStopHooks()
                continue
            }

            // 6. 无 tool_calls — LLM 只返回了文本，循环结束
            agentLogger.info("No tool calls, Agent Loop ending after \(iterationCount) iterations")
            await runStopHooks()
            break
        }

        if iterationCount >= maxIterations {
            agentLogger.warning("Agent Loop hit max iterations limit (\(maxIterations))")
            await runStopHooks()
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

    // MARK: - R1 Helper: Special Tool Events

    /// 特殊工具事件发射 — TodoWrite/AskUserQuestion/EnterPlanMode/ExitPlanMode 工具执行后发射对应 UI 事件
    private func emitSpecialToolEvents(
        name: String,
        result: ToolResult,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        switch name {
        case "todo_write":
            // TodoWrite — 从 metadata 解析 todoCount
            let count = Int(result.metadata["todoCount"] ?? "0") ?? 0
            if count > 0 {
                // 构建简化的 TodoItem 数组（从 output 解析）
                let items = parseTodoItemsFromOutput(result.output)
                continuation.yield(.todoUpdated(items))
            }

        case "enter_plan_mode":
            continuation.yield(.planModeEntered)

        case "exit_plan_mode":
            let approved = result.metadata["approved"] == "true"
            if approved {
                continuation.yield(.planApproved)
            } else {
                continuation.yield(.planRejected(reason: "用户拒绝了计划"))
            }

        case "ask_user_question":
            // 从 metadata 解析 questions JSON
            if let questionsJSON = result.metadata["questions"],
               let data = questionsJSON.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var questions: [UserQuestion] = []
                for item in array {
                    let header = item["header"] as? String ?? ""
                    let question = item["question"] as? String ?? ""
                    let options = item["options"] as? [String]
                    questions.append(UserQuestion(header: header, question: question, options: options))
                }
                if !questions.isEmpty {
                    continuation.yield(.askUserQuestion(questions: questions))
                }
            }

        // R2: Sub-agent + Task + MCP 事件
        case "agent":
            if let agentName = result.metadata["agentName"] {
                continuation.yield(.agentSpawned(name: agentName, task: result.metadata["subagentType"] ?? "general-purpose"))
                continuation.yield(.agentCompleted(name: agentName, result: result.output))
            }

        case "task_create":
            if let taskIdString = result.metadata["taskId"],
               let subject = result.metadata["taskSubject"],
               let taskId = UUID(uuidString: taskIdString) {
                let task = TaskItem(id: taskId, subject: subject, description: "")
                continuation.yield(.taskCreated(task))
            }

        case "task_update":
            if let taskIdString = result.metadata["taskId"],
               let taskId = UUID(uuidString: taskIdString) {
                let status = result.metadata["taskStatus"] ?? "pending"
                let task = TaskItem(id: taskId, subject: "", description: "", status: TaskStatus(rawValue: status) ?? .pending)
                continuation.yield(.taskUpdated(task))
            }

        case "mcp_tool_call":
            if let serverId = result.metadata["serverId"],
               let mcpToolName = result.metadata["mcpToolName"] {
                continuation.yield(.mcpToolCall(serverId: serverId, toolName: mcpToolName))
            }

        case "send_message":
            if let recipient = result.metadata["recipient"],
               let summary = result.metadata["summary"] {
                continuation.yield(.messageReceived(from: "main", content: summary))
            }

        default:
            break
        }
    }

    /// 从 TodoWriteTool 输出文本解析 TodoItem 数组（简化解析）
    private func parseTodoItemsFromOutput(_ output: String) -> [TodoItem] {
        var items: [TodoItem] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("✅") || trimmed.hasPrefix("🔄") || trimmed.hasPrefix("⬜") {
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let status: String
                if trimmed.hasPrefix("✅") { status = "completed" }
                else if trimmed.hasPrefix("🔄") { status = "in_progress" }
                else { status = "pending" }
                items.append(TodoItem(id: UUID().uuidString, content: content, status: status))
            }
        }
        return items
    }

    // MARK: - R1: Skill Matching

    /// 检查用户输入是否匹配已安装技能的触发词
    /// - Parameter userMessage: 用户输入文本
    /// - Returns: 匹配的技能名称（如果有）
    func matchSkill(input: String) async -> String? {
        guard let registry = skillRegistry else { return nil }
        if let skill = await registry.matchSkill(input: input) {
            return skill.name
        }
        return nil
    }

    // MARK: - R1: Command Parsing

    /// 检查用户输入是否为 slash 命令
    /// - Parameter userMessage: 用户输入文本
    /// - Returns: (命令名, 参数数组) 如果匹配
    func parseCommand(input: String) async -> (name: String, args: [String])? {
        guard let registry = commandRegistry else { return nil }
        guard let (command, args) = await registry.parse(input: input) else { return nil }
        return (command.name, args)
    }

    // MARK: - R1: Memory Extraction + T05 Stop Hooks

    /// T05: 注册 stop hook — 每次 query loop 结束时触发
    /// - Parameter hook: 异步回调
    func registerStopHook(_ hook: @escaping @Sendable () async -> Void) {
        stopHooks.append(hook)
    }

    /// T05: 运行所有 stop hooks（在每次循环迭代结束时调用）
    private func runStopHooks() async {
        for hook in stopHooks {
            await hook()
        }
    }

    /// 会话结束后自动提取记忆（异步，不阻塞 .completed）
    /// Bug #4 fix: 移除冗余的双层 guard，skillRegistry 在此方法中未被使用
    func extractMemories() async {
        guard let store = memoryStore else { return }
        let extractor = MemoryExtractor()
        await extractor.extractAndStore(
            session: session,
            apiGateway: apiGateway,
            memoryStore: store,
            scope: .user
        )
    }
}