import Foundation

/// Agent 事件枚举 — AgentLoop 通过 AsyncThrowingStream<AgentEvent> 向 UI 推送事件
/// 每个 AgentEvent 对应 Agent Loop 中的一步状态变化
/// UI 层订阅此事件流，实现流式文本显示、工具调用状态可视化、权限弹窗等
enum AgentEvent: Sendable {
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
        }
    }

    /// 是否需要用户交互（askConfirmation 类型）
    var requiresUserInteraction: Bool {
        if case .askConfirmation = self { return true }
        return false
    }
}