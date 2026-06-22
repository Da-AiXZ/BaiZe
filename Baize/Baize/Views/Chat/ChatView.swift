import SwiftUI
import UIKit

/// 对话面板完整视图 — 集成 AgentLoop 事件流
/// 订阅 AgentLoop 的 AsyncThrowingStream<AgentEvent>，流式显示 LLM 响应
/// 支持工具调用状态可视化、权限确认交互
struct ChatView: View {
    @ObservedObject var appState: AppState
    @State private var displayMessages: [DisplayMessage] = []
    @State private var inputText: String = ""
    @State private var isStreaming: Bool = false
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var agentLoop: AgentLoop?
    // Bug 6 fix: 使用 StreamingTextBuffer 替代 streamingText @State，
    // 节流 @Published 更新频率（每 80ms 一次而非每个 textDelta）
    @StateObject private var streamBuffer = StreamingTextBuffer()
    @State private var hasReceivedAnyResponse: Bool = false
    @State private var isCompacting: Bool = false
    // P2-5: 上下文用量指示器状态
    @State private var contextTokens: Int = 0
    @State private var contextWindow: Int = BaizeToken.maxContextTokens
    @State private var hasCompacted: Bool = false
    // P1-1: 会话持久化 UI 状态
    @State private var showSessionList: Bool = false
    @State private var savedSessions: [ConversationSession] = []
    @State private var currentSessionId: UUID?
    // Bug 2 fix: 持有 agentTask 以便切换会话时取消；agentGeneration 用于丢弃旧 loop 的事件
    @State private var agentTask: Task<Void, Never>?
    @State private var agentGeneration: Int = 0
    // Bug 7 fix: 切换会话时强制 ScrollView 重建，清除旧滚动位置
    @State private var scrollIdentity: UUID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // 对话标题 + Agent 状态
            ChatHeader(
                appState: appState,
                isStreaming: isStreaming,
                onShowSessionList: { showSessionList = true }
            )

            // 消息列表
            // Bug 6 fix: 传入 streamBuffer.displayedText（节流后的显示文本）
            // Bug 7 fix: .id(scrollIdentity) 强制 ScrollView 在切换会话时重建，清除旧滚动位置
            ChatMessageList(
                messages: displayMessages,
                streamingText: streamBuffer.displayedText,
                isStreaming: isStreaming
            )
            .id(scrollIdentity)

            // P2-5: 上下文用量指示器
            ContextUsageBar(
                tokens: contextTokens,
                window: contextWindow,
                hasCompacted: hasCompacted
            )

            // P0-2: 压缩 Loading 状态（摘要 LLM 调用期间显示）
            if isCompacting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("🔄 正在压缩上下文...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.baizeCardBackground)
            }

            // 权限确认弹窗（内嵌）
            if let confirmation = pendingConfirmation {
                PermissionDialog(
                    toolCall: confirmation.toolCall,
                    reason: confirmation.reason,
                    onAllow: { handleConfirmation(allowed: true) },
                    onDeny: { handleConfirmation(allowed: false) }
                )
            }

            Divider()

            // 输入框
            // Bug 3 fix: 添加 onStop 回调，运行时显示停止按钮
            ChatInputView(
                text: $inputText,
                isRunning: appState.isAgentRunning,
                onSend: { sendMessage($0) },
                onStop: { stopAgent() },
                appState: appState
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeChatBackground)
        // P1-1: 启动时加载会话列表
        .onAppear {
            Task { await loadSessionList() }
        }
        // T03: 项目切换时重新加载会话列表（按新 projectPath 过滤）
        .onChange(of: appState.currentProjectPath) { _ in
            Task { await loadSessionList() }
        }
        // P1-1: 会话列表 Sheet
        .sheet(isPresented: $showSessionList) {
            SessionListView(
                sessions: savedSessions,
                currentSessionId: currentSessionId,
                onSelect: { session in
                    Task { await restoreSession(session) }
                },
                onNewSession: { startNewSession() },
                projectPath: appState.currentProjectPath,
                conversationStore: appState.conversationStore
            )
        }
        // R1: PlanMode 审批弹窗
        .sheet(isPresented: $appState.showPlanApprovalSheet) {
            if let plan = appState.pendingPlanForApproval {
                PlanApprovalView(
                    plan: plan,
                    onApprove: {
                        appState.showPlanApprovalSheet = false
                        Task {
                            if let planMode = appState.planModeState {
                                await planMode.approve()
                            }
                        }
                    },
                    onReject: { reason in
                        appState.showPlanApprovalSheet = false
                        Task {
                            if let planMode = appState.planModeState {
                                await planMode.reject(reason: reason)
                            }
                        }
                    }
                )
            }
        }
        // R1: 结构化提问弹窗
        .sheet(isPresented: $appState.showAskUserQuestionSheet) {
            if let questions = appState.pendingQuestions {
                AskUserQuestionView(
                    questions: questions,
                    onSubmit: { answers in
                        appState.showAskUserQuestionSheet = false
                        appState.pendingQuestions = nil
                        // 将用户回答作为系统消息注入对话
                        let answerText = questions.enumerated().map { (index, q) in
                            "Q: \(q.question)\nA: \(answers[index])"
                        }.joined(separator: "\n\n")
                        displayMessages.append(DisplayMessage(
                            role: .user,
                            content: answerText,
                            timestamp: Date()
                        ))
                    }
                )
            }
        }
    }

    // MARK: - Message Handling

    private func sendMessage(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // W9 fix: 防止重复提交 — 如果 Agent 已经在运行，拒绝新消息
        guard !appState.isAgentRunning else {
            baizeLogger.warning("Attempted to send message while agent is running, ignoring")
            return
        }

        // 添加用户消息
        displayMessages.append(DisplayMessage(
            role: .user,
            content: message,
            timestamp: Date()
        ))

        inputText = ""
        isStreaming = true
        // Bug 6 fix: 使用 streamBuffer 替代 streamingText
        streamBuffer.reset()
        hasReceivedAnyResponse = false

        // W9 fix: 在 Task 之前同步设置 isAgentRunning = true，防止时序竞争
        appState.isAgentRunning = true
        // 焦点自动切换：Agent 运行时切到对话面板焦点（双保险，ContentView 的 onChange 也会触发）
        // Bug 5 fix: 使用 withAnimation 包裹，替代原 WorkspacePane 上的 .animation 修饰符
        withAnimation(.easeInOut(duration: 0.3)) {
            appState.focusMode = .chat
        }

        // 启动 Agent Loop（异步任务）
        // Bug 2 fix: 持有 Task 引用，切换会话时可取消
        let gen = agentGeneration
        agentTask = Task {
            await runAgentLoop(userMessage: message, generation: gen)
        }
    }

    /// 运行 AgentLoop 并处理事件流
    /// W5 fix: 使用 AppState 中注入的共享服务实例，不再每次重建
    /// Bug 2 fix: generation 参数用于检测会话切换，丢弃旧 loop 的事件
    private func runAgentLoop(userMessage: String, generation: Int) async {
        // W5 fix: 从 AppState 获取共享服务，避免每次发消息都重建新实例
        guard let apiGateway = appState.apiGateway,
              let toolRegistry = appState.toolRegistry,
              let permissionEngine = appState.permissionEngine,
              let contextManager = appState.contextManager,
              let conversationStore = appState.conversationStore,
              let fileSystemService = appState.fileSystemService,
              let runtimeExecutor = appState.runtimeExecutor else {
            await MainActor.run {
                displayMessages.append(DisplayMessage(
                    role: .error,
                    content: "服务未初始化，请重启应用",
                    timestamp: Date()
                ))
                isStreaming = false
            }
            return
        }

        // 同步 APIGateway 与 AppState — 确保发送消息时使用正确的 Provider 和模型
        // 修复：setActiveProvider 是异步 Task，可能在用户发消息时还没执行完
        do {
            try await apiGateway.setActiveProvider(
                providerId: appState.activeProvider.providerId,
                model: appState.activeModel
            )
        } catch {
            baizeLogger.error("Failed to sync APIGateway before message: \(error.localizedDescription)")
            await MainActor.run {
                displayMessages.append(DisplayMessage(
                    role: .error,
                    content: "Provider 同步失败: \(error.localizedDescription)。请到设置页点击「应用选择」后重试。",
                    timestamp: Date()
                ))
                isStreaming = false
                appState.isAgentRunning = false
            }
            return
        }

        // 诊断：记录当前 Provider 和模型
        let providerId = await apiGateway.getActiveProviderId()
        let activeModel = await apiGateway.getActiveModel()
        baizeLogger.info("ChatView: sending message with provider=\(providerId), model=\(activeModel)")

        // P0-1: 复用已有 AgentLoop（跨轮历史修复），或首次创建新实例
        // 核心修复：不再每轮新建 ConversationSession + AgentLoop，导致历史归零
        let loop: AgentLoop
        if let existingLoop = self.agentLoop {
            // 复用：同一对话窗口内，session.messages 已含前序轮次完整历史
            loop = existingLoop
            baizeLogger.info("Reusing existing AgentLoop for continued conversation")
        } else {
            // 首次创建：新 ConversationSession + 新 AgentLoop
            let session = ConversationSession(projectPath: appState.currentProjectPath)
            baizeLogger.info("ChatView: new session projectPath=\(session.projectPath)")
            loop = AgentLoop(
                apiGateway: apiGateway,
                toolRegistry: toolRegistry,
                permissionEngine: permissionEngine,
                contextManager: contextManager,
                conversationStore: conversationStore,
                fileSystemService: fileSystemService,
                runtimeExecutor: runtimeExecutor,
                skillRegistry: appState.skillRegistry,
                memoryStore: appState.memoryStore,
                commandRegistry: appState.commandRegistry,
                planModeState: appState.planModeState,
                webSearchProvider: appState.webSearchProvider,
                taskList: appState.taskList,
                teamCoordinator: appState.teamCoordinator,
                mcpManager: appState.mcpManager,
                gitService: appState.gitService,
                session: session
            )
            self.agentLoop = loop
            baizeLogger.info("Created new AgentLoop for new conversation")
            // P1-3: 新建 AgentLoop 后同步当前模型的 contextWindow
            await loop.updateContextWindow(resolveContextWindow())
        }

        let eventStream = await loop.run(userMessage: userMessage)

        do {
            for try await event in eventStream {
                // Bug 2 fix: 会话切换后丢弃旧 loop 的事件，防止内容串到新会话
                if Task.isCancelled { break }
                let isStale = await MainActor.run { self.agentGeneration != generation }
                if isStale {
                    baizeLogger.warning("Discarding stale agent event: session switched (gen=\(generation))")
                    break
                }
                await handleAgentEvent(event)
            }
        } catch {
            // Bug 2 fix: 会话已切换则跳过错误处理（防止错误消息串到新会话）
            let isStale = await MainActor.run { self.agentGeneration != generation }
            guard !isStale else { return }
            await MainActor.run {
                displayMessages.append(DisplayMessage(
                    role: .error,
                    content: "Agent 错误: \(error.localizedDescription)",
                    timestamp: Date()
                ))
                isStreaming = false
                // W9 fix: 错误时也重置 isAgentRunning，防止按钮永久禁用
                appState.isAgentRunning = false
                // Bug 5 fix: 错误时也收起键盘
                DispatchQueue.main.async {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        }

        // Bug 2 fix: 会话已切换则跳过清理（防止干扰新会话状态）
        let isStaleCleanup = await MainActor.run { self.agentGeneration != generation }
        guard !isStaleCleanup else { return }

        await MainActor.run {
            isStreaming = false
            // W9 fix: 正常结束时也确保重置 isAgentRunning（双重保险）
            // 注意：.completed 事件已经设置了 isAgentRunning = false，
            // 但如果 stream 未正常 yield .completed（如被取消），这里兜底重置
            appState.isAgentRunning = false
            // Bug 5 fix: 兜底收起键盘
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
    }

    /// 处理 AgentEvent — 转换为 UI 显示消息
    @MainActor
    private func handleAgentEvent(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text):
            // Bug 6 fix: 累积到 buffer（不触发 UI 重绘），由 timer 每 80ms flush
            streamBuffer.append(text)
            hasReceivedAnyResponse = true

        case .toolCall(let toolCall):
            // 将当前流式文本转为正式消息
            // Bug 6 fix: flush 确保获取完整文本
            streamBuffer.flush()
            if !streamBuffer.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamBuffer.fullText,
                    timestamp: Date()
                ))
                streamBuffer.reset()
            }
            displayMessages.append(DisplayMessage(
                role: .toolCall,
                content: "调用 \(toolCall.name)",
                timestamp: Date(),
                toolCall: toolCall,
                toolStatus: .pending
            ))

        case .toolExecuting(let toolCall):
            // P0-5 fix: 传入完整 toolCall（含完整参数），更新 UI 中之前为空的参数
            updateToolCallStatus(id: toolCall.id, status: .executing, toolCall: toolCall)

        case .toolResult(let toolCall, let result):
            // P0-5 fix: 传入完整 toolCall（含完整参数），更新 UI 中之前为空的参数
            updateToolCallStatus(id: toolCall.id, status: .completed, result: result, toolCall: toolCall)
            // Agent 工具执行后刷新编辑器（如果修改了文件）
            if toolCall.name == "write_file" || toolCall.name == "edit_file" {
                let path = toolCall.argumentString(for: "path") ?? ""
                if !path.isEmpty {
                    // 触发编辑器刷新
                    appState.objectWillChange.send()
                }
            }

        case .denied(let toolCall, let reason):
            // P0-5 fix: 传入完整 toolCall（含完整参数）
            updateToolCallStatus(id: toolCall.id, status: .denied, denialReason: reason, toolCall: toolCall)

        case .askConfirmation(let toolCall, let reason):
            pendingConfirmation = PendingConfirmation(toolCall: toolCall, reason: reason)

        case .error(let error):
            hasReceivedAnyResponse = true
            // Bug 6 fix: flush 确保获取完整文本
            streamBuffer.flush()
            if !streamBuffer.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamBuffer.fullText,
                    timestamp: Date()
                ))
                streamBuffer.reset()
            }
            displayMessages.append(DisplayMessage(
                role: .error,
                content: "错误: \(error.localizedDescription)",
                timestamp: Date()
            ))

        case .contextCompacting:
            // P0-2: 压缩开始 — UI 显示"正在压缩"状态
            isCompacting = true

        case .contextCompacted(let summary, let compactedCount, let retainedCount):
            // P0-2: 压缩完成 — 插入压缩提示（UI 层标记，不进入 LLM 上下文）
            isCompacting = false
            hasCompacted = true
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "📦 上下文已压缩:已将 \(compactedCount) 条历史消息摘要为 1 条,保留最近 \(retainedCount) 条完整对话",
                timestamp: Date()
            ))

        case .contextCompactionFailed(let error):
            // P0-2: 压缩失败降级 — 提示用户，Agent 继续工作
            isCompacting = false
            hasCompacted = true
            displayMessages.append(DisplayMessage(
                role: .error,
                content: "⚠️ 上下文压缩失败:\(error)。已保留最近对话,Agent 继续工作。",
                timestamp: Date()
            ))

        case .contextUsage(let tokens, let window):
            // P2-5: 更新上下文用量指示器
            contextTokens = tokens
            contextWindow = window

        case .commandExecuting(let command, _):
            // P1-2: Agent 命令联动 — 转发到终端面板
            // 不影响 displayMessages（终端和对话是独立通道）
            appState.terminalViewModel?.appendAgentCommand(command)

        case .commandOutput(_, let output, _, let exitCode):
            // P1-2: Agent 命令输出 — 转发到终端面板
            appState.terminalViewModel?.appendAgentOutput(output, exitCode: exitCode)

        case .completed:
            // Bug 6 fix: flush 确保获取完整文本
            streamBuffer.flush()
            if !streamBuffer.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamBuffer.fullText,
                    timestamp: Date()
                ))
                streamBuffer.reset()
            } else if !hasReceivedAnyResponse {
                // 空响应兜底：AgentLoop 完成但未收到任何文本或错误
                let providerId = appState.activeProvider.providerId
                let model = appState.activeModel
                displayMessages.append(DisplayMessage(
                    role: .error,
                    content: "未收到任何响应。当前 Provider: \(providerId), 模型: \(model)。请到设置页确认配置正确后点击「应用选择」，然后重试。",
                    timestamp: Date()
                ))
            }
            appState.isAgentRunning = false
            // Bug 5 fix: AI 响应完成后主动收起键盘，防止输入框自动获焦
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
            // Agent 完成后焦点保持 .chat，用户手动切回 .code
            // P1-1: 对话完成后刷新会话列表（新消息已保存到磁盘）
            Task { await loadSessionList() }

        // R1/R2 新增事件处理
        case .todoUpdated(let items):
            // TodoWrite 工具输出 — 更新 AppState 中的 todoItems 供 TaskListView 显示
            appState.todoItems = items
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "📋 任务清单已更新（\(items.count) 项）",
                timestamp: Date()
            ))

        case .planModeEntered:
            appState.isPlanModeActive = true
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "🔍 已进入计划模式（只读操作）",
                timestamp: Date()
            ))

        case .planApprovalRequested(let plan):
            appState.pendingPlanForApproval = plan
            appState.showPlanApprovalSheet = true

        case .planApproved:
            appState.isPlanModeActive = false
            appState.showPlanApprovalSheet = false
            appState.pendingPlanForApproval = nil
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "✅ 计划已批准，开始执行",
                timestamp: Date()
            ))

        case .planRejected(let reason):
            appState.isPlanModeActive = false
            appState.showPlanApprovalSheet = false
            appState.pendingPlanForApproval = nil
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "❌ 计划被拒绝: \(reason)",
                timestamp: Date()
            ))

        case .askUserQuestion(let questions):
            appState.pendingQuestions = questions
            appState.showAskUserQuestionSheet = true

        case .skillTriggered(let skillName):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "⚡ 技能触发: \(skillName)",
                timestamp: Date()
            ))

        case .memoryInjected(let count):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "🧠 注入 \(count) 条相关记忆",
                timestamp: Date()
            ))

        // R2 新增事件（T04 Sub-agent 相关，T03 阶段做基本显示）
        case .taskCreated(let task):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "📝 任务创建: \(task.subject)",
                timestamp: Date()
            ))

        case .taskUpdated(let task):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "📝 任务更新: \(task.subject) → \(task.status)",
                timestamp: Date()
            ))

        case .agentSpawned(let name, let task):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "🤖 子 agent 启动: \(name) — \(task)",
                timestamp: Date()
            ))

        case .agentCompleted(let name, let result):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "🤖 子 agent 完成: \(name) — \(result)",
                timestamp: Date()
            ))

        case .mcpToolCall(let serverId, let toolName):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "🔌 MCP 调用: \(serverId)/\(toolName)",
                timestamp: Date()
            ))

        case .messageReceived(let from, let content):
            displayMessages.append(DisplayMessage(
                role: .system,
                content: "📨 收到消息 from \(from): \(content)",
                timestamp: Date()
            ))
        }
    }

    /// 更新工具调用状态
    private func updateToolCallStatus(
        id: String,
        status: ToolCallView.ToolCallStatus,
        result: ToolResult? = nil,
        denialReason: String? = nil,
        toolCall: ToolCall? = nil
    ) {
        for index in displayMessages.indices {
            if displayMessages[index].toolCall?.id == id {
                displayMessages[index].toolStatus = status
                displayMessages[index].toolResult = result
                displayMessages[index].denialReason = denialReason
                // P0-5 fix: 更新 toolCall 以获取完整参数
                // 初始 .toolCall 事件携带的 ToolCall 参数为空（arguments 尚未流式接收完成）
                // .toolExecuting / .toolResult 事件携带的 ToolCall 参数完整
                if let tc = toolCall {
                    displayMessages[index].toolCall = tc
                }
            }
        }
    }

    /// 处理权限确认结果
    private func handleConfirmation(allowed: Bool) {
        guard let confirmation = pendingConfirmation else { return }
        guard let loop = agentLoop else { return }
        pendingConfirmation = nil
        Task {
            await loop.confirmToolCall(toolCall: confirmation.toolCall, allowed: allowed)
        }
    }

    /// Bug 3 fix: 用户主动停止 Agent 生成
    /// 递增 generation 使旧 task 的事件被丢弃，cancel task，停止 loop，flush 残留文本
    private func stopAgent() {
        // 递增 generation，使旧 task 的 catch/cleanup 被跳过
        agentGeneration += 1
        // 取消正在运行的 agentTask
        agentTask?.cancel()
        // 停止 AgentLoop
        if let loop = agentLoop {
            Task { await loop.stop() }
        }
        // Flush 残留的流式文本并转为正式消息
        streamBuffer.flush()
        if !streamBuffer.isEmpty {
            displayMessages.append(DisplayMessage(
                role: .assistant,
                content: streamBuffer.fullText,
                timestamp: Date()
            ))
            streamBuffer.reset()
        }
        isStreaming = false
        appState.isAgentRunning = false
        // 收起键盘
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
        // 刷新会话列表
        Task { await loadSessionList() }
    }

    // MARK: - Session Persistence (P1-1)

    /// 加载已保存的会话列表
    /// T03: 按 appState.currentProjectPath 过滤，只显示当前项目的会话
    private func loadSessionList() async {
        guard let store = appState.conversationStore else { return }
        let allSessions = await store.listSessions()
        // T03: 按 projectPath 过滤
        let projectPath = appState.currentProjectPath
        let filtered = allSessions.filter { $0.projectPath == projectPath }
        await MainActor.run { self.savedSessions = filtered }
    }

    /// 恢复历史会话 — 创建新 AgentLoop 加载恢复的 session
    /// Bug 2 fix: 递增 generation + 取消 agentTask，防止旧 loop 的事件串到恢复的会话
    private func restoreSession(_ restored: ConversationSession) async {
        // Bug 2 fix: 递增 generation，使旧 loop 的后续事件被丢弃
        agentGeneration += 1
        // 取消正在运行的 agentTask
        agentTask?.cancel()
        // 停止当前 AgentLoop（如果在运行）
        if let loop = agentLoop {
            await loop.stop()
        }

        guard let apiGateway = appState.apiGateway,
              let toolRegistry = appState.toolRegistry,
              let permissionEngine = appState.permissionEngine,
              let contextManager = appState.contextManager,
              let conversationStore = appState.conversationStore,
              let fileSystemService = appState.fileSystemService,
              let runtimeExecutor = appState.runtimeExecutor else { return }

        let loop = AgentLoop(
            apiGateway: apiGateway,
            toolRegistry: toolRegistry,
            permissionEngine: permissionEngine,
            contextManager: contextManager,
            conversationStore: conversationStore,
            fileSystemService: fileSystemService,
            runtimeExecutor: runtimeExecutor,
            skillRegistry: appState.skillRegistry,
            memoryStore: appState.memoryStore,
            commandRegistry: appState.commandRegistry,
            planModeState: appState.planModeState,
            webSearchProvider: appState.webSearchProvider,
            taskList: appState.taskList,
                teamCoordinator: appState.teamCoordinator,
                mcpManager: appState.mcpManager,
                gitService: appState.gitService,
                session: restored
            )
        let window = resolveContextWindow()
        await loop.updateContextWindow(window)

        await MainActor.run {
            self.agentLoop = loop
            self.currentSessionId = restored.id
            self.displayMessages = restored.messages.toDisplayMessages()
            self.hasCompacted = restored.messages.contains { $0.isSummary }
            self.contextTokens = restored.estimatedTokens
            self.contextWindow = window
            // Bug 6 fix: 使用 streamBuffer
            self.streamBuffer.reset()
            self.isStreaming = false
            self.showSessionList = false
            // Bug 7 fix: 重置 scrollIdentity 强制 ScrollView 重建，清除旧滚动位置
            self.scrollIdentity = UUID()
        }
    }

    /// 开始新会话 — 清空当前状态
    /// Bug 2 fix: 取消正在运行的 agentTask + 立即创建并保存空 session（使其出现在列表中）
    private func startNewSession() {
        // Bug 2 fix: 递增 generation，使旧 loop 的后续事件被丢弃
        agentGeneration += 1
        // 取消正在运行的 agentTask
        agentTask?.cancel()
        // 停止当前 AgentLoop（如果在运行）
        if let loop = agentLoop {
            Task { await loop.stop() }
        }
        self.agentLoop = nil
        self.currentSessionId = nil
        self.displayMessages = []
        self.hasCompacted = false
        self.contextTokens = 0
        // Bug 6 fix: 使用 streamBuffer
        self.streamBuffer.reset()
        self.isStreaming = false
        self.appState.isAgentRunning = false
        self.showSessionList = false
        // Bug 7 fix: 重置 scrollIdentity 强制 ScrollView 重建，清除旧滚动位置
        self.scrollIdentity = UUID()

        // Bug 2 fix: 立即创建并保存空 session + 创建对应 AgentLoop，
        // 使新对话立即出现在列表中，且后续 sendMessage 能复用此 loop（不会创建第二个 session）
        Task {
            guard let apiGateway = appState.apiGateway,
                  let toolRegistry = appState.toolRegistry,
                  let permissionEngine = appState.permissionEngine,
                  let contextManager = appState.contextManager,
                  let conversationStore = appState.conversationStore,
                  let fileSystemService = appState.fileSystemService,
                  let runtimeExecutor = appState.runtimeExecutor else {
                await loadSessionList()
                return
            }
            let session = ConversationSession(projectPath: appState.currentProjectPath)
            try? await conversationStore.save(session: session)
            let loop = AgentLoop(
                apiGateway: apiGateway,
                toolRegistry: toolRegistry,
                permissionEngine: permissionEngine,
                contextManager: contextManager,
                conversationStore: conversationStore,
                fileSystemService: fileSystemService,
                runtimeExecutor: runtimeExecutor,
                skillRegistry: appState.skillRegistry,
                memoryStore: appState.memoryStore,
                commandRegistry: appState.commandRegistry,
                planModeState: appState.planModeState,
                webSearchProvider: appState.webSearchProvider,
                taskList: appState.taskList,
                teamCoordinator: appState.teamCoordinator,
                mcpManager: appState.mcpManager,
                gitService: appState.gitService,
                session: session
            )
            await loop.updateContextWindow(resolveContextWindow())
            await MainActor.run {
                self.agentLoop = loop
                self.currentSessionId = session.id
            }
            await loadSessionList()
        }
    }

    /// 根据当前 activeProvider + activeModel 解析 contextWindow
    /// 匹配 BaizeModels 模型列表，未匹配时回退 BaizeToken.maxContextTokens
    /// Bug 3 fix: Custom Provider 无 ModelInfo，使用 appState.customContextWindow
    private func resolveContextWindow() -> Int {
        // Custom Provider：直接返回用户配置的 contextWindow
        if appState.activeProvider == .custom {
            return appState.customContextWindow
        }
        let models: [ModelInfo]
        switch appState.activeProvider {
        case .openAI:     models = BaizeModels.OpenAI.allModels
        case .anthropic:  models = BaizeModels.Anthropic.allModels
        case .openRouter: models = BaizeModels.OpenRouter.allModels
        case .custom:     models = []
        }
        if let info = models.first(where: { $0.id == appState.activeModel }) {
            return info.contextWindow
        }
        return BaizeToken.maxContextTokens
    }
}
