import SwiftUI

/// 对话面板完整视图 — 集成 AgentLoop 事件流
/// 订阅 AgentLoop 的 AsyncThrowingStream<AgentEvent>，流式显示 LLM 响应
/// 支持工具调用状态可视化、权限确认交互
struct ChatView: View {
    @ObservedObject var appState: AppState
    @State private var displayMessages: [DisplayMessage] = []
    @State private var inputText: String = ""
    @State private var isStreaming: Bool = false
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var streamingText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 对话标题 + Agent 状态
            ChatHeader(appState: appState, isStreaming: isStreaming)

            // 消息列表
            ChatMessageList(
                messages: displayMessages,
                streamingText: streamingText,
                isStreaming: isStreaming
            )

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
            ChatInputView(
                text: $inputText,
                isRunning: appState.isAgentRunning,
                onSend: { sendMessage($0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeChatBackground)
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
        streamingText = ""

        // W9 fix: 在 Task 之前同步设置 isAgentRunning = true，防止时序竞争
        appState.isAgentRunning = true

        // 启动 Agent Loop（异步任务）
        Task {
            await runAgentLoop(userMessage: message)
        }
    }

    /// 运行 AgentLoop 并处理事件流
    /// W5 fix: 使用 AppState 中注入的共享服务实例，不再每次重建
    private func runAgentLoop(userMessage: String) async {
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

        let agentLoop = AgentLoop(
            apiGateway: apiGateway,
            toolRegistry: toolRegistry,
            permissionEngine: permissionEngine,
            contextManager: contextManager,
            conversationStore: conversationStore,
            fileSystemService: fileSystemService,
            runtimeExecutor: runtimeExecutor
        )

        let eventStream = agentLoop.run(userMessage: userMessage)

        do {
            for try await event in eventStream {
                await handleAgentEvent(event)
            }
        } catch {
            await MainActor.run {
                displayMessages.append(DisplayMessage(
                    role: .error,
                    content: "Agent 错误: \(error.localizedDescription)",
                    timestamp: Date()
                ))
                isStreaming = false
                // W9 fix: 错误时也重置 isAgentRunning，防止按钮永久禁用
                appState.isAgentRunning = false
            }
        }

        await MainActor.run {
            isStreaming = false
            // W9 fix: 正常结束时也确保重置 isAgentRunning（双重保险）
            // 注意：.completed 事件已经设置了 isAgentRunning = false，
            // 但如果 stream 未正常 yield .completed（如被取消），这里兜底重置
            appState.isAgentRunning = false
        }
    }

    /// 处理 AgentEvent — 转换为 UI 显示消息
    @MainActor
    private func handleAgentEvent(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text):
            streamingText += text

        case .toolCall(let toolCall):
            // 将当前流式文本转为正式消息
            if !streamingText.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamingText,
                    timestamp: Date()
                ))
                streamingText = ""
            }
            displayMessages.append(DisplayMessage(
                role: .toolCall,
                content: "调用 \(toolCall.name)",
                timestamp: Date(),
                toolCall: toolCall,
                toolStatus: .pending
            ))

        case .toolExecuting(let toolCall):
            updateToolCallStatus(id: toolCall.id, status: .executing)

        case .toolResult(let toolCall, let result):
            updateToolCallStatus(id: toolCall.id, status: .completed, result: result)
            // Agent 工具执行后刷新编辑器（如果修改了文件）
            if toolCall.name == "write_file" || toolCall.name == "edit_file" {
                let path = toolCall.argumentString(for: "path") ?? ""
                if !path.isEmpty {
                    // 触发编辑器刷新
                    appState.objectWillChange.send()
                }
            }

        case .denied(let toolCall, let reason):
            updateToolCallStatus(id: toolCall.id, status: .denied, denialReason: reason)

        case .askConfirmation(let toolCall, let reason):
            pendingConfirmation = PendingConfirmation(toolCall: toolCall, reason: reason)

        case .error(let error):
            if !streamingText.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamingText,
                    timestamp: Date()
                ))
                streamingText = ""
            }
            displayMessages.append(DisplayMessage(
                role: .error,
                content: "错误: \(error.localizedDescription)",
                timestamp: Date()
            ))

        case .completed:
            if !streamingText.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamingText,
                    timestamp: Date()
                ))
                streamingText = ""
            }
            appState.isAgentRunning = false
        }
    }

    /// 更新工具调用状态
    private func updateToolCallStatus(
        id: String,
        status: ToolCallView.ToolCallStatus,
        result: ToolResult? = nil,
        denialReason: String? = nil
    ) {
        for index in displayMessages.indices {
            if displayMessages[index].toolCall?.id == id {
                displayMessages[index].toolStatus = status
                displayMessages[index].toolResult = result
                displayMessages[index].denialReason = denialReason
            }
        }
    }

    /// 处理权限确认结果
    private func handleConfirmation(allowed: Bool) {
        pendingConfirmation = nil
        // TODO: 在 T05 集成时，将确认结果传递给 AgentLoop
        if allowed {
            baizeLogger.info("User allowed tool execution")
        } else {
            baizeLogger.info("User denied tool execution")
        }
    }
}

// MARK: - Display Message Model

/// UI 显示消息模型 — 区分文本消息、工具调用、工具结果、错误
struct DisplayMessage: Identifiable {
    let id = UUID()
    let role: DisplayRole
    var content: String
    let timestamp: Date
    var toolCall: ToolCall?
    /// W12 fix: ToolCallStatus 从 ToolCallView 引入，不再在 DisplayMessage 中重复定义
    var toolStatus: ToolCallView.ToolCallStatus?
    var toolResult: ToolResult?
    var denialReason: String?

    enum DisplayRole {
        case user
        case assistant
        case toolCall
        case error
    }

// W12 fix: 删除重复的 ToolCallStatus enum，使用 ToolCallView.ToolCallStatus
}

// MARK: - Pending Confirmation

/// 待确认的工具调用
struct PendingConfirmation {
    let toolCall: ToolCall
    let reason: String
}

// MARK: - Chat Header

/// 对话面板标题栏 — 显示 Agent 运行状态
private struct ChatHeader: View {
    @ObservedObject var appState: AppState
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("对话")
                .font(.headline)

            if isStreaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Agent 正在思考...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(appState.permissionMode.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.baizeAccent.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground)
    }
}

// MARK: - Chat Message List

/// 消息滚动列表
private struct ChatMessageList: View {
    let messages: [DisplayMessage]
    let streamingText: String
    let isStreaming: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // 流式文本（Agent 正在输出）
                    if isStreaming && !streamingText.isEmpty {
                        StreamingTextBubble(text: streamingText)
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: streamingText) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            if let lastId = messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            } else {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }
}

// MARK: - Streaming Text Bubble

/// 流式文本气泡 — Agent 正在输出时使用
private struct StreamingTextBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.baizeAccent)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.baizeBubbleAssistant)
                    .cornerRadius(12)

                Text("正在输出...")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer(minLength: 40)
        }
    }
}