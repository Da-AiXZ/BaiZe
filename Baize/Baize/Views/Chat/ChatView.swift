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
    @State private var streamingText: String = ""
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

    var body: some View {
        VStack(spacing: 0) {
            // 对话标题 + Agent 状态
            ChatHeader(
                appState: appState,
                isStreaming: isStreaming,
                onShowSessionList: { showSessionList = true }
            )

            // 消息列表
            ChatMessageList(
                messages: displayMessages,
                streamingText: streamingText,
                isStreaming: isStreaming
            )

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
            ChatInputView(
                text: $inputText,
                isRunning: appState.isAgentRunning,
                onSend: { sendMessage($0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeChatBackground)
        // P1-1: 启动时加载会话列表
        .onAppear {
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
                onNewSession: { startNewSession() }
            )
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
        streamingText = ""
        hasReceivedAnyResponse = false

        // W9 fix: 在 Task 之前同步设置 isAgentRunning = true，防止时序竞争
        appState.isAgentRunning = true
        // 焦点自动切换：Agent 运行时切到对话面板焦点（双保险，ContentView 的 onChange 也会触发）
        appState.focusMode = .chat

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
                session: session
            )
            self.agentLoop = loop
            baizeLogger.info("Created new AgentLoop for new conversation")
            // P1-3: 新建 AgentLoop 后同步当前模型的 contextWindow
            await loop.updateContextWindow(resolveContextWindow())
        }

        let eventStream = try await loop.run(userMessage: userMessage)

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
                // Bug 5 fix: 错误时也收起键盘
                DispatchQueue.main.async {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        }

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
            streamingText += text
            hasReceivedAnyResponse = true

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
            hasReceivedAnyResponse = true
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

        case .completed:
            if !streamingText.isEmpty {
                displayMessages.append(DisplayMessage(
                    role: .assistant,
                    content: streamingText,
                    timestamp: Date()
                ))
                streamingText = ""
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
        guard let confirmation = pendingConfirmation else { return }
        guard let loop = agentLoop else { return }
        pendingConfirmation = nil
        Task {
            await loop.confirmToolCall(toolCall: confirmation.toolCall, allowed: allowed)
        }
    }

    // MARK: - Session Persistence (P1-1)

    /// 加载已保存的会话列表
    private func loadSessionList() async {
        guard let store = appState.conversationStore else { return }
        let sessions = await store.listSessions()
        await MainActor.run { self.savedSessions = sessions }
    }

    /// 恢复历史会话 — 创建新 AgentLoop 加载恢复的 session
    private func restoreSession(_ restored: ConversationSession) async {
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
            self.streamingText = ""
            self.isStreaming = false
            self.showSessionList = false
        }
    }

    /// 开始新会话 — 清空当前状态
    private func startNewSession() {
        self.agentLoop = nil
        self.currentSessionId = nil
        self.displayMessages = []
        self.hasCompacted = false
        self.contextTokens = 0
        self.streamingText = ""
        self.isStreaming = false
        self.showSessionList = false
        Task { await loadSessionList() }
    }

    /// 根据当前 activeProvider + activeModel 解析 contextWindow
    /// 匹配 BaizeModels 模型列表，未匹配时回退 BaizeToken.maxContextTokens
    private func resolveContextWindow() -> Int {
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
        case system
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
/// 配色适配 DeepSeek 蓝白（.purple → baizeAccent）
private struct ChatHeader: View {
    @ObservedObject var appState: AppState
    let isStreaming: Bool
    let onShowSessionList: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // P1-1: 会话列表按钮（左侧）
            Button(action: onShowSessionList) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 16))
                    .foregroundColor(.baizeTextSecondary)
            }
            .buttonStyle(.plain)

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

            // Phase 2C: 模型指示器（baizeAccent 配色）
            Text("\(appState.activeProvider.displayName) / \(appState.activeModel)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.baizeAccent.opacity(0.1))
                .cornerRadius(4)

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
/// Bug 4 fix: 修复自动滚底逻辑 + 添加悬浮"滚到底"按钮
private struct ChatMessageList: View {
    let messages: [DisplayMessage]
    let streamingText: String
    let isStreaming: Bool

    // Bug 4 fix: 滚动位置追踪
    @State private var contentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    /// 是否显示"滚到底"按钮 — 当用户上滑且不在底部时显示
    private var showScrollToBottomButton: Bool {
        let maxScrollOffset = contentHeight - scrollViewHeight
        return maxScrollOffset > 120 && scrollOffset < maxScrollOffset - 120
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
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
                    // Bug 4 fix: 追踪内容高度和滚动偏移
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ChatContentHeightKey.self, value: geo.size.height)
                                .preference(key: ChatScrollOffsetKey.self,
                                            value: -geo.frame(in: .named("chatScroll")).minY)
                        }
                    )
                }
                .coordinateSpace(name: "chatScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatScrollViewHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ChatContentHeightKey.self) { contentHeight = $0 }
                .onPreferenceChange(ChatScrollViewHeightKey.self) { scrollViewHeight = $0 }
                .onPreferenceChange(ChatScrollOffsetKey.self) { offset in
                    scrollOffset = offset
                }
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: streamingText) { _ in
                    scrollToBottom(proxy: proxy)
                }

                // Bug 4 fix: 悬浮"滚到底"按钮
                if showScrollToBottomButton {
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.3)) {
                            scrollToBottom(proxy: proxy)
                        }
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(Color.baizeAccent)
                            .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                            .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    /// Bug 4 fix: 滚动到底部 — 流式输出时滚到 streaming，否则滚到最后一条消息
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            if isStreaming && !streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastId = messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Scroll Preference Keys (Bug 4 fix)

/// 内容高度偏好键
private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// ScrollView 可视高度偏好键
private struct ChatScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 滚动偏移偏好键
private struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

// MARK: - Context Usage Bar (P2-5)

/// 上下文用量指示器 — 显示当前 token 用量 / contextWindow + 颜色分级 + 进度条
/// 颜色分级：
///   - hasCompacted = true → 绿色（已压缩，历史被摘要）
///   - ratio >= 0.7 → 橙色（接近阈值，即将触发压缩）
///   - 正常 → 灰色
private struct ContextUsageBar: View {
    let tokens: Int
    let window: Int
    let hasCompacted: Bool

    /// 用量比例 (0.0 ~ 1.0)
    private var ratio: Double {
        guard window > 0 else { return 0 }
        return Double(tokens) / Double(window)
    }

    /// 格式化 token 数为可读字符串
    /// 低于 1K 时显示原始数字，高于 1K 时显示 1 位小数 K，高于 1M 时显示 M
    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        } else if value >= 1000 {
            return String(format: "%.1fK", Double(value) / 1000.0)
        } else {
            return "\(value)"
        }
    }

    /// 格式化 contextWindow 为可读字符串
    private func formatWindow(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.0fM", Double(value) / 1_000_000.0)
        } else if value >= 1000 {
            return String(format: "%.0fK", Double(value) / 1000.0)
        } else {
            return "\(value)"
        }
    }

    /// 颜色分级
    private var barColor: Color {
        if hasCompacted {
            return .baizeSuccess
        } else if ratio >= 0.7 {
            return .baizeWarning
        } else {
            return .baizeTextSecondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // 📦 图标：已压缩时显示
            if hasCompacted {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundColor(.baizeSuccess)
            }

            Text("上下文: \(formatTokens(tokens)) / \(formatWindow(window)) (\(String(format: "%.1f", ratio * 100))%)")
                .font(.caption)
                .foregroundColor(barColor)

            ProgressView(value: Double(tokens), total: Double(max(window, 1)))
                .progressViewStyle(LinearProgressViewStyle(tint: barColor))
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 28)
        .background(Color.baizeCardBackground)
    }
}

// MARK: - Session List View (P1-1)

/// 会话列表视图 — 显示已保存的对话，支持选择恢复或新建
private struct SessionListView: View {
    let sessions: [ConversationSession]
    let currentSessionId: UUID?
    let onSelect: (ConversationSession) -> Void
    let onNewSession: () -> Void

    var body: some View {
        NavigationView {
            List {
                // 顶部新建会话按钮
                Section {
                    Button(action: onNewSession) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.baizeAccent)
                            Text("新建会话")
                                .foregroundColor(.baizeAccent)
                        }
                    }
                }

                // 已保存的会话列表
                Section {
                    if sessions.isEmpty {
                        Text("暂无历史会话")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            SessionRow(
                                session: session,
                                isCurrent: session.id == currentSessionId
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(session)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 单个会话行 — 标题 + 相对时间 + 消息数
private struct SessionRow: View {
    let session: ConversationSession
    let isCurrent: Bool

    /// 会话标题：优先用首条用户消息前 30 字，否则用 session.title
    private var displayTitle: String {
        for message in session.messages {
            if case .user(let text) = message {
                let firstLine = text.split(separator: "\n").first ?? ""
                let title = String(firstLine.prefix(30))
                return title.isEmpty ? session.title : title
            }
        }
        return session.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.baizeSuccess)
                }
                Text(displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.baizeTextPrimary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(session.updatedAt.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)

                Text("\(session.messages.count) 条消息")
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
