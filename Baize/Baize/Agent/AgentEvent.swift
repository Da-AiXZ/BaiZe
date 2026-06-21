import Foundation

// MARK: - UI Support Types

/// Todo 项 — TodoWriteTool 维护的任务清单条目
/// T01 占位骨架，T03（TodoWriteTool）补全完整实现
public struct TodoItem: Sendable {
    /// 唯一标识
    public let id: String
    /// 任务内容
    public var content: String
    /// 任务状态 — pending / in_progress / completed
    public var status: String

    public init(id: String, content: String, status: String = "pending") {
        self.id = id
        self.content = content
        self.status = status
    }
}

/// 用户问题 — AskUserQuestionTool 的结构化提问单元
/// T01 占位骨架，T03（AskUserQuestionTool）补全完整实现
public struct UserQuestion: Sendable {
    /// 问题标题
    public let header: String
    /// 问题正文
    public let question: String
    /// 可选选项列表（nil 表示自由文本回答）
    public let options: [String]?

    public init(header: String, question: String, options: [String]? = nil) {
        self.header = header
        self.question = question
        self.options = options
    }
}

/// Agent 事件枚举 — AgentLoop 通过 AsyncThrowingStream<AgentEvent> 向 UI 推送事件
/// 每个 AgentEvent 对应 Agent Loop 中的一步状态变化
/// UI 层订阅此事件流，实现流式文本显示、工具调用状态可视化、权限弹窗等
/// W20 fix: 使用 @unchecked Sendable 而非 Sendable
/// 原因：.error(Error) 中的 Error 协议本身不是 Sendable，
/// 但实际使用中只会传递 BaizeError（enum，符合 Sendable）或
/// Swift 并发框架中的 Sendable Error（如 CancellationError），
/// 跨隔离边界传递后仅做 localizedDescription 读取，不会产生数据竞争
enum AgentEvent: @unchecked Sendable {
    /// LLM 文本增量输出（SSE stream content delta）
    case textDelta(String)

    /// 工具调用开始（LLM 返回 tool_call，尚未执行）
    case toolCall(ToolCall)

    /// 工具正在执行中（已通过权限检查，正在运行）
    case toolExecuting(ToolCall)

    /// 工具执行完成，返回结果
    case toolResult(ToolCall, ToolResult)

    /// 工具调用被拒绝（权限引擎 deny 或用户 deny）
    case denied(ToolCall, String)

    /// 需要用户确认（权限引擎 ask，等待用户 allow/deny）
    case askConfirmation(ToolCall, String)

    /// Agent Loop 发生错误
    case error(Error)

    /// Agent Loop 完成（LLM 不再返回 tool_call，对话结束）
    case completed

    /// 上下文压缩开始 — UI 显示"正在压缩上下文..."
    case contextCompacting

    /// 上下文压缩完成 — 携带摘要文本、被压缩条数、保留条数
    case contextCompacted(summary: String, compactedCount: Int, retainedCount: Int)

    /// 上下文压缩失败 — 携带错误描述，降级为近期消息保留
    case contextCompactionFailed(error: String)

    /// 上下文用量更新 — 携带当前估算 token 数和 contextWindow
    case contextUsage(estimatedTokens: Int, contextWindow: Int)

    /// 终端命令开始执行（Agent 调用 execute_command 工具时）
    /// - Parameter command: 执行的命令字符串
    /// - Parameter source: 命令来源（.agent — AgentLoop 发射时固定为 .agent）
    case commandExecuting(command: String, source: CommandSource)

    /// 终端命令输出完成（Agent 调用 execute_command 工具后）
    /// - Parameter command: 执行的命令字符串
    /// - Parameter output: 命令输出（stdout + stderr）
    /// - Parameter source: 命令来源
    /// - Parameter exitCode: 退出码（0 = 成功，非 0 = 失败）
    case commandOutput(command: String, output: String, source: CommandSource, exitCode: Int)

    // MARK: - R1 新增事件（PlanMode / Skills / Memory / Todo / AskUser）

    /// TodoWrite 工具输出 — 携带更新后的任务清单
    case todoUpdated([TodoItem])

    /// 进入计划模式（EnterPlanModeTool 触发）
    case planModeEntered

    /// 退出计划模式，请求用户审批计划（ExitPlanModeTool 触发）
    /// - Parameter plan: AI 生成的计划文本
    case planApprovalRequested(plan: String)

    /// 计划审批通过 — 用户点击"批准"
    case planApproved

    /// 计划审批拒绝 — 用户点击"拒绝"
    /// - Parameter reason: 用户拒绝原因
    case planRejected(reason: String)

    /// 结构化提问（AskUserQuestionTool 触发）— UI 弹出多问题表单
    /// - Parameter questions: 问题列表
    case askUserQuestion(questions: [UserQuestion])

    /// 技能触发 — 检测到匹配的 Skill 并开始执行
    /// - Parameter skillName: 触发的技能名称（kebab-case）
    case skillTriggered(skillName: String)

    /// 记忆注入 — 新会话开始时注入相关记忆到 system prompt
    /// - Parameter count: 注入的记忆条数
    case memoryInjected(count: Int)

    // MARK: - R2 新增事件（Sub-agent / Task / MCP / Message）

    /// 任务创建 — TaskCreateTool 创建新任务
    /// - Parameter task: 创建的任务
    case taskCreated(TaskItem)

    /// 任务更新 — TaskUpdateTool 更新任务状态
    /// - Parameter task: 更新后的任务
    case taskUpdated(TaskItem)

    /// 子 agent 启动 — AgentTool spawn 子 agent
    /// - Parameter name: 子 agent 名称
    /// - Parameter task: 分配给子 agent 的任务描述
    case agentSpawned(name: String, task: String)

    /// 子 agent 完成 — 子 agent 返回结果
    /// - Parameter name: 子 agent 名称
    /// - Parameter result: 子 agent 的最终结果文本
    case agentCompleted(name: String, result: String)

    /// MCP 工具调用 — 调用远程/本地 MCP server 的工具
    /// - Parameter serverId: MCP server 标识
    /// - Parameter toolName: MCP 工具名称
    case mcpToolCall(serverId: String, toolName: String)

    /// Agent 间消息接收 — SendMessageTool 从其他 agent 收到消息
    /// - Parameter from: 发送方 agent 名称
    /// - Parameter content: 消息内容
    case messageReceived(from: String, content: String)
}

// MARK: - AgentEvent Convenience

extension AgentEvent {
    /// 事件的人类可读描述
    var description: String {
        switch self {
        case .textDelta(let text): return "文本输出: \(text.prefix(50))..."
        case .toolCall(let call): return "工具调用: \(call.name)"
        case .toolExecuting(let call): return "正在执行: \(call.name)"
        case .toolResult(let call, let result): return "工具结果: \(call.name) → \(result.output.prefix(30))"
        case .denied(let call, let reason): return "被拒绝: \(call.name) — \(reason)"
        case .askConfirmation(let call, let reason): return "需确认: \(call.name) — \(reason)"
        case .error(let err): return "错误: \(err.localizedDescription)"
        case .completed: return "对话完成"
        case .contextCompacting: return "正在压缩上下文"
        case .contextCompacted(let summary, let compactedCount, let retainedCount):
            return "上下文已压缩: \(compactedCount)条→摘要, 保留\(retainedCount)条 — \(summary.prefix(50))..."
        case .contextCompactionFailed(let error): return "上下文压缩失败: \(error)"
        case .contextUsage(let estimatedTokens, let contextWindow):
            return "上下文用量: \(estimatedTokens)/\(contextWindow) tokens"

        case .commandExecuting(let command, let source):
            return "命令执行中: \(command) [\(source == .agent ? "Agent" : "用户")]"

        case .commandOutput(let command, let output, let source, let exitCode):
            return "命令输出: \(command) → exit=\(exitCode), \(output.prefix(30))..."

        // R1 新增事件
        case .todoUpdated(let items): return "任务清单更新: \(items.count) 项"
        case .planModeEntered: return "已进入计划模式"
        case .planApprovalRequested(let plan): return "请求审批计划: \(plan.prefix(50))..."
        case .planApproved: return "计划已批准"
        case .planRejected(let reason): return "计划已拒绝: \(reason)"
        case .askUserQuestion(let questions): return "结构化提问: \(questions.count) 个问题"
        case .skillTriggered(let skillName): return "技能触发: \(skillName)"
        case .memoryInjected(let count): return "记忆注入: \(count) 条"

        // R2 新增事件
        case .taskCreated(let task): return "任务创建: \(task.subject)"
        case .taskUpdated(let task): return "任务更新: \(task.subject) → \(task.status)"
        case .agentSpawned(let name, let task): return "子 agent 启动: \(name) — \(task.prefix(30))"
        case .agentCompleted(let name, let result): return "子 agent 完成: \(name) — \(result.prefix(30))"
        case .mcpToolCall(let serverId, let toolName): return "MCP 调用: \(serverId)/\(toolName)"
        case .messageReceived(let from, let content): return "消息接收: \(from) — \(content.prefix(30))"
        }
    }

    /// 是否需要用户交互（askConfirmation 类型）
    var requiresUserInteraction: Bool {
        if case .askConfirmation = self { return true }
        return false
    }
}