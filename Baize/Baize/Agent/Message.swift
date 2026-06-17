import Foundation

/// 消息模型 — 对话中的单条消息
/// 支持 5 种角色：system, user, assistant, tool_call, tool_result
/// 与 OpenAI Chat Completions API 的 message 格式对应
/// 用于构建 LLM 请求上下文和 UI 显示
///
/// 修复 C1/C2：assistant 消息现在可同时携带文本和 tool_calls 列表，
/// 符合 OpenAI API 要求（多个 tool_call 必须在同一个 assistant 消息中）
enum Message: Sendable, Identifiable {
    /// 系统提示消息（定义 Agent 角色和行为规范）
    case system(String)

    /// 用户输入消息
    case user(String)

    /// LLM 文本回复（不含 tool_call）
    case assistant(String)

    /// LLM 回复同时包含文本和 tool_calls（OpenAI API 要求合并为单条 assistant 消息）
    case assistantWithToolCalls(content: String, toolCalls: [ToolCall])

    /// LLM 发起的工具调用（仅 tool_call，无文本 — 内部存储用）
    /// 注意：此 case 仅用于消息存储的向后兼容，新增消息应使用 assistantWithToolCalls
    case toolCall(id: String, name: String, arguments: String)

    /// 工具执行结果返回给 LLM
    case toolResult(id: String, content: String)

    // MARK: - Identifiable

    /// 使用 UUID 保证 id 稳定性（修复 W17: hashValue 跨进程不稳定）
    var id: String {
        switch self {
        case .system(let text): return "system-\(text.stableHash)"
        case .user(let text): return "user-\(text.stableHash)"
        case .assistant(let text): return "assistant-\(text.stableHash)"
        case .assistantWithToolCalls(let content, let toolCalls):
            return "assistant-tc-\(content.stableHash)-\(toolCalls.map(\.id).joined(separator: ","))"
        case .toolCall(let id, _, _): return "toolcall-\(id)"
        case .toolResult(let id, _): return "toolresult-\(id)"
        }
    }

    // MARK: - Convenience Properties

    /// 消息角色标识（用于 UI 显示）
    var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .assistantWithToolCalls: return "assistant"
        case .toolCall: return "tool_call"
        case .toolResult: return "tool_result"
        }
    }

    /// 消息文本内容
    var content: String {
        switch self {
        case .system(let text): return text
        case .user(let text): return text
        case .assistant(let text): return text
        case .assistantWithToolCalls(let content, _): return content
        case .toolCall(_, let name, let arguments): return "调用 \(name): \(arguments)"
        case .toolResult(_, let content): return content
        }
    }

    /// 是否为用户消息
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    /// 是否为工具调用
    var isToolCall: Bool {
        switch self {
        case .toolCall: return true
        case .assistantWithToolCalls: return true
        default: return false
        }
    }

    /// 是否为工具结果
    var isToolResult: Bool {
        if case .toolResult = self { return true }
        return false
    }

    /// 是否为包含 tool_calls 的 assistant 消息
    var hasToolCalls: Bool {
        if case .assistantWithToolCalls = self { return true }
        return false
    }

    // MARK: - OpenAI API Format Conversion

    /// 转换为 OpenAI Chat Completions API 的消息格式
    /// 格式：
    ///   system:  {"role": "system", "content": "..."}
    ///   user:    {"role": "user", "content": "..."}
    ///   assistant (text only): {"role": "assistant", "content": "..."}
    ///   assistant (with tool_calls): {"role": "assistant", "content": "...", "tool_calls": [...]}
    ///   tool_result: {"role": "tool", "tool_call_id": "...", "content": "..."}
    ///
    /// 修复 C1：tool_call 消息不再独立输出，而是在 API 层合并。
    /// 本方法对 .toolCall case 仍保留输出（用于向后兼容），但建议使用
    /// APIGateway.buildRequest() 中的消息合并逻辑确保 OpenAI 格式正确。
    func toOpenAIFormat() -> [String: Any] {
        switch self {
        case .system(let text):
            return ["role": "system", "content": text]

        case .user(let text):
            return ["role": "user", "content": text]

        case .assistant(let text):
            return ["role": "assistant", "content": text]

        case .assistantWithToolCalls(let content, let toolCalls):
            let toolCallsFormat = toolCalls.map { call -> [String: Any] in
                return [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ]
                ]
            }
            var result: [String: Any] = [
                "role": "assistant",
                "tool_calls": toolCallsFormat,
            ]
            // 当文本内容不为空时，同时携带 content 字段
            if !content.isEmpty {
                result["content"] = content
            } else {
                result["content"] = nil
            }
            return result

        case .toolCall(let id, let name, let arguments):
            // 独立 toolCall 消息 — 在 API 请求前应被合并
            // 保留此格式用于消息存储和向后兼容
            return [
                "role": "assistant",
                "content": nil,
                "tool_calls": [
                    [
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments,
                        ]
                    ]
                ]
            ] as [String: Any]

        case .toolResult(let id, let content):
            return [
                "role": "tool",
                "tool_call_id": id,
                "content": content,
            ]
        }
    }
}

// MARK: - String Stable Hash Extension

/// 字符串稳定哈希扩展 — 用于生成跨进程稳定的消息 ID
/// 替代 hashValue（每次程序启动可能不同）
private extension String {
    /// 基于字符内容的确定性哈希值
    var stableHash: Int {
        // 使用 djb2 算法生成确定性哈希
        var hash: Int = 5381
        for byte in self.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return hash
    }
}

// MARK: - Message Array OpenAI Format Merge

extension Array where Element == Message {
    /// 将消息列表转换为 OpenAI API 兼容格式
    /// 合并连续的 .toolCall 消息为单个 assistant 消息（修复 C1）
    /// 如果 .assistant 文本消息后紧跟 .toolCall，合并为一个 assistant 消息（修复 C2）
    func toOpenAIMergedFormat() -> [[String: Any]] {
        var result: [[String: Any]] = []
        var i = 0

        while i < count {
            let message = self[i]

            switch message {
            case .system, .user, .toolResult, .assistantWithToolCalls:
                // 这些消息格式已正确，直接输出
                result.append(message.toOpenAIFormat())
                i += 1

            case .assistant(let text):
                // 检查下一条消息是否是连续的 toolCall（修复 C2）
                if i + 1 < count && self[i + 1].isConsecutiveToolCall {
                    // 收集后续连续的 toolCall
                    var toolCalls: [ToolCall] = []
                    var j = i + 1
                    while j < count && self[j].isConsecutiveToolCall {
                        if case .toolCall(let id, let name, let arguments) = self[j] {
                            toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                        }
                        j += 1
                    }
                    // 合并为一个 assistantWithToolCalls 消息
                    let mergedMessage = Message.assistantWithToolCalls(content: text, toolCalls: toolCalls)
                    result.append(mergedMessage.toOpenAIFormat())
                    i = j
                } else {
                    result.append(message.toOpenAIFormat())
                    i += 1
                }

            case .toolCall:
                // 连续的 toolCall 消息需要合并为单个 assistant 消息
                var toolCalls: [ToolCall] = []
                var j = i
                while j < count && self[j].isConsecutiveToolCall {
                    if case .toolCall(let id, let name, let arguments) = self[j] {
                        toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                    }
                    j += 1
                }
                // 合并为空文本的 assistantWithToolCalls 消息
                let mergedMessage = Message.assistantWithToolCalls(content: "", toolCalls: toolCalls)
                result.append(mergedMessage.toOpenAIFormat())
                i = j
            }
        }

        return result
    }
}

// MARK: - Message Private Helpers

private extension Message {
    /// 判断是否为连续的 toolCall 消息（用于合并逻辑）
    var isConsecutiveToolCall: Bool {
        if case .toolCall = self { return true }
        return false
    }
}

// MARK: - Conversation Session

/// 对话会话 — 包含一组消息和相关元数据
struct ConversationSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]
    let projectPath: String
    let createdAt: Date
    var updatedAt: Date

    /// 创建新对话会话
    init(
        id: UUID = UUID(),
        title: String = "新对话",
        messages: [Message] = [],
        projectPath: String = BaizePath.projectRoot,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 估算当前消息的总 Token 数
    /// 考虑 assistantWithToolCalls 中 tool_calls 参数的 token 开销
    var estimatedTokens: Int {
        messages.reduce(0) { sum, msg in
            let baseTokens = msg.content.estimatedTokens
            let toolCallTokens: Int
            if case .assistantWithToolCalls(_, let toolCalls) = msg {
                toolCallTokens = toolCalls.reduce(0) { tcSum, tc in
                    tcSum + tc.arguments.estimatedTokens + tc.name.estimatedTokens
                }
            } else {
                toolCallTokens = 0
            }
            return sum + baseTokens + toolCallTokens
        }
    }
}

// MARK: - Message Codable Support

/// Message 的 Codable 实现（因为 enum with associated values 需手动实现）
extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, content, toolCallId, toolCallName, toolCallArguments, toolResultId, toolResultContent
        case toolCalls // 用于 assistantWithToolCalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)

        switch role {
        case "system":
            let content = try container.decode(String.self, forKey: .content)
            self = .system(content)
        case "user":
            let content = try container.decode(String.self, forKey: .content)
            self = .user(content)
        case "assistant":
            let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            // 尝试解码 toolCalls 数组
            if let toolCallsData = try? container.decode([ToolCall].self, forKey: .toolCalls) {
                self = .assistantWithToolCalls(content: content, toolCalls: toolCallsData)
            } else {
                self = .assistant(content)
            }
        case "assistant_with_tool_calls":
            // 向后兼容：旧格式可能使用单独的 role 标识
            let content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            let toolCalls = try container.decode([ToolCall].self, forKey: .toolCalls)
            self = .assistantWithToolCalls(content: content, toolCalls: toolCalls)
        case "tool_call":
            let id = try container.decode(String.self, forKey: .toolCallId)
            let name = try container.decode(String.self, forKey: .toolCallName)
            let arguments = try container.decode(String.self, forKey: .toolCallArguments)
            self = .toolCall(id: id, name: name, arguments: arguments)
        case "tool_result":
            let id = try container.decode(String.self, forKey: .toolResultId)
            let content = try container.decode(String.self, forKey: .toolResultContent)
            self = .toolResult(id: id, content: content)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "Unknown message role: \(role)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let content):
            try container.encode("system", forKey: .role)
            try container.encode(content, forKey: .content)
        case .user(let content):
            try container.encode("user", forKey: .role)
            try container.encode(content, forKey: .content)
        case .assistant(let content):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
        case .assistantWithToolCalls(let content, let toolCalls):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encode(toolCalls, forKey: .toolCalls)
        case .toolCall(let id, let name, let arguments):
            try container.encode("tool_call", forKey: .role)
            try container.encode(id, forKey: .toolCallId)
            try container.encode(name, forKey: .toolCallName)
            try container.encode(arguments, forKey: .toolCallArguments)
        case .toolResult(let id, let content):
            try container.encode("tool_result", forKey: .role)
            try container.encode(id, forKey: .toolResultId)
            try container.encode(content, forKey: .toolResultContent)
        }
    }
}