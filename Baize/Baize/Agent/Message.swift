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

    // MARK: - Summary Detection (P0-2: 哨兵前缀机制)

    /// 是否为上下文摘要消息（检测哨兵前缀 `📦 [上下文摘要]`）
    /// 摘要消息复用 .assistant case + 哨兵前缀，不新增 Message case
    var isSummary: Bool {
        if case .assistant(let text) = self {
            return text.hasPrefix(BaizeSummary.sentinelPrefix)
        }
        return false
    }

    /// 提取纯摘要文本（剥离哨兵前缀）
    /// 若非摘要消息则返回 nil
    var summaryText: String? {
        if case .assistant(let text) = self, text.hasPrefix(BaizeSummary.sentinelPrefix) {
            return String(text.dropFirst(BaizeSummary.sentinelPrefix.count))
        }
        return nil
    }

    /// 创建摘要消息（复用 .assistant case + 哨兵前缀）
    /// - Parameter text: 摘要正文（不含哨兵前缀）
    /// - Returns: .assistant(sentinelPrefix + text)
    static func summary(_ text: String) -> Message {
        .assistant(BaizeSummary.sentinelPrefix + text)
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

    // MARK: - Anthropic API Format Conversion

    /// 转换为 Anthropic Messages API 的消息格式
    /// Anthropic 格式与 OpenAI 有以下差异：
    ///   - system 消息不在 messages 数组中，提取到顶层 system 参数
    ///   - assistant with tool_calls 使用 content blocks 格式
    ///   - tool_result 使用 user 角色 + tool_result content block
    ///   - 不存在独立的 toolCall 消息（合并到 assistant 消息）
    func toAnthropicFormat() -> [String: Any] {
        switch self {
        case .system:
            // system 消息不在 messages 数组中，由 toAnthropicMessages() 提取到顶层
            // 此处返回空字典，调用方应使用 toAnthropicMessages() 而非逐条转换
            return [:]

        case .user(let text):
            return ["role": "user", "content": text]

        case .assistant(let text):
            return ["role": "assistant", "content": text]

        case .assistantWithToolCalls(let content, let toolCalls):
            // Anthropic 使用 content blocks 格式
            var contentBlocks: [[String: Any]] = []

            // 文本 block（即使为空也不添加空文本 block，除非没有 tool_calls）
            if !content.isEmpty {
                contentBlocks.append(["type": "text", "text": content])
            }

            // tool_use blocks
            for call in toolCalls {
                // 解析 arguments JSON 为对象
                var inputObject: Any = [:]
                if let data = call.arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    inputObject = parsed
                }
                contentBlocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": inputObject,
                ])
            }

            // 如果没有文本也没有 tool_calls（不应发生），添加空文本
            if contentBlocks.isEmpty {
                contentBlocks.append(["type": "text", "text": ""])
            }

            return ["role": "assistant", "content": contentBlocks]

        case .toolCall:
            // 独立 toolCall 消息 — 在 Anthropic 格式中应合并到 assistant 消息
            // 此处返回空字典，调用方应使用 toAnthropicMessages() 处理合并
            return [:]

        case .toolResult(let id, let content):
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": content,
                    ]
                ]
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

// MARK: - Message Array Anthropic Format Conversion

extension Array where Element == Message {
    /// 将消息列表转换为 Anthropic Messages API 格式
    /// 提取 system 消息为顶层 system 参数，合并连续 toolCall 消息
    /// - Returns: (system: 顶层 system 字符串, messages: 非系统消息数组)
    func toAnthropicMessages() -> (system: String?, messages: [[String: Any]]) {
        // 1. 提取所有 system 消息拼接为顶层 system 参数
        var systemParts: [String] = []
        var nonSystemMessages: [Message] = []

        for message in self {
            if case .system(let text) = message {
                systemParts.append(text)
            } else {
                nonSystemMessages.append(message)
            }
        }

        let systemPrompt = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        // 2. 合并连续的 toolCall 消息（与 toOpenAIMergedFormat 逻辑一致）
        var result: [[String: Any]] = []
        var i = 0

        while i < nonSystemMessages.count {
            let message = nonSystemMessages[i]

            switch message {
            case .user, .toolResult, .assistantWithToolCalls:
                result.append(message.toAnthropicFormat())
                i += 1

            case .assistant(let text):
                // 检查下一条消息是否是连续的 toolCall
                if i + 1 < nonSystemMessages.count && nonSystemMessages[i + 1].isConsecutiveToolCall {
                    // 收集后续连续的 toolCall
                    var toolCalls: [ToolCall] = []
                    var j = i + 1
                    while j < nonSystemMessages.count && nonSystemMessages[j].isConsecutiveToolCall {
                        if case .toolCall(let id, let name, let arguments) = nonSystemMessages[j] {
                            toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                        }
                        j += 1
                    }
                    // 合并为一个 assistantWithToolCalls 消息
                    let mergedMessage = Message.assistantWithToolCalls(content: text, toolCalls: toolCalls)
                    result.append(mergedMessage.toAnthropicFormat())
                    i = j
                } else {
                    result.append(message.toAnthropicFormat())
                    i += 1
                }

            case .toolCall:
                // 连续的 toolCall 消息需要合并为单个 assistant 消息
                var toolCalls: [ToolCall] = []
                var j = i
                while j < nonSystemMessages.count && nonSystemMessages[j].isConsecutiveToolCall {
                    if case .toolCall(let id, let name, let arguments) = nonSystemMessages[j] {
                        toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                    }
                    j += 1
                }
                // 合并为空文本的 assistantWithToolCalls 消息
                let mergedMessage = Message.assistantWithToolCalls(content: "", toolCalls: toolCalls)
                result.append(mergedMessage.toAnthropicFormat())
                i = j

            case .system:
                // 已在上方提取，不应到达此处
                i += 1
            }
        }

        return (system: systemPrompt, messages: result)
    }
}

// MARK: - Message Array Tool Result Repair (Bug 1 fix: API 400 safety net)

extension Array where Element == Message {
    /// 修复孤立的 tool_call — 为没有对应 tool_result 的 tool_call_id 注入占位结果
    ///
    /// OpenAI API 要求：assistant 消息中的每个 tool_call_id 必须有对应的 tool 消息。
    /// 如果由于任何原因（工具执行异常、竞态等）导致 tool_result 缺失，
    /// 下一次 API 调用会返回 HTTP 400：
    /// "An assistant message with 'tool_calls' must be followed by tool messages
    ///  responding to each tool_call_id (insufficient tool messages following tool calls)"
    ///
    /// 此方法作为安全网，在发送 API 请求前检查并修复孤立 tool_call。
    /// - Returns: 修复后的消息数组（可能追加了占位 tool_result 消息）
    func repairingOrphanedToolCalls() -> [Message] {
        // 收集所有 tool_call id（来自 .assistantWithToolCalls 和 .toolCall）
        var toolCallIds: Set<String> = []
        for msg in self {
            switch msg {
            case .assistantWithToolCalls(_, let toolCalls):
                toolCallIds.formUnion(toolCalls.map(\.id))
            case .toolCall(let id, _, _):
                toolCallIds.insert(id)
            default:
                break
            }
        }

        // 收集所有 tool_result id
        var toolResultIds: Set<String> = []
        for msg in self {
            if case .toolResult(let id, _) = msg {
                toolResultIds.insert(id)
            }
        }

        // 找出没有对应 tool_result 的 tool_call id
        let orphanedIds = toolCallIds.subtracting(toolResultIds)
        if orphanedIds.isEmpty {
            return self
        }

        // 为每个孤立 id 注入占位 tool_result
        agentLogger.warning("repairingOrphanedToolCalls: found \(orphanedIds.count) orphaned tool_call(s), injecting placeholder tool_results: \(orphanedIds)")
        var result = self
        for id in orphanedIds {
            result.append(.toolResult(id: id, content: "[工具执行结果缺失 — 已自动补全以防止 API 400 错误]"))
        }
        return result
    }
}

// MARK: - Message Array Token Estimation (P0-4: 统一 token 估算)

extension Array where Element == Message {
    /// 统一 token 估算 — 全项目唯一消息级实现
    /// 包含：消息文本 content + tool_call name/arguments + tool_result content
    /// 底层原语为 String.estimatedTokens (utf8 × 0.25)
    var estimatedTokens: Int {
        reduce(0) { sum, msg in
            let baseTokens = msg.content.estimatedTokens
            let toolCallTokens: Int
            switch msg {
            case .assistantWithToolCalls(_, let toolCalls):
                toolCallTokens = toolCalls.reduce(0) { $0 + $1.arguments.estimatedTokens + $1.name.estimatedTokens }
            case .toolCall(_, let name, let arguments):
                toolCallTokens = name.estimatedTokens + arguments.estimatedTokens
            default:
                toolCallTokens = 0
            }
            return sum + baseTokens + toolCallTokens
        }
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
    /// P0-4: 委托给统一的 Array<Message>.estimatedTokens 扩展
    /// （补算 .assistantWithToolCalls 和 .toolCall 的 tool_calls token）
    var estimatedTokens: Int {
        messages.estimatedTokens
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