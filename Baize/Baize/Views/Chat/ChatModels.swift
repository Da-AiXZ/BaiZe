import Foundation

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
