import Foundation

/// 工具执行结果模型 — Tool 执行完成后返回的结构化结果
/// 包含：输出文本、是否为错误结果、附加元数据
/// 错误结果也会返回给 LLM（isError: true），让 LLM 根据错误信息调整策略
/// W3 fix: metadata 使用 [String: String] 类型（而非 [String: Any]）：
/// - 所有 tool 实现已使用字符串插值存储数值（如 "exitCode": "\(result.exitCode)"）
/// - [String: String] 符合 Sendable + Codable，而 [String: Any] 不符合
/// - 类型一致性得到保证，无需改为 [String: Any]
struct ToolResult: Sendable, Codable {
    /// 工具执行输出（stdout 或格式化结果）
    let output: String

    /// 是否为错误结果（执行失败、权限拒绝等）
    let isError: Bool

    /// 附加元数据（如文件路径、执行时间等）
    /// W3 fix: 类型为 [String: String]，所有数值通过字符串插值存储
    let metadata: [String: String]

    // MARK: - Initialization

    init(output: String, isError: Bool = false, metadata: [String: String] = [:]) {
        // 截断过长输出 — P2-1: 安全网阈值上调至 maxResultSafetyNet，
        // 分层截断由 ToolResultTruncator 在 AgentLoop 注入前处理
        self.output = output.truncated(to: BaizeRuntime.maxResultSafetyNet)
        self.isError = isError
        self.metadata = metadata
    }

    // MARK: - Convenience Constructors

    /// 成功结果
    static func success(output: String, metadata: [String: String] = [:]) -> ToolResult {
        ToolResult(output: output, isError: false, metadata: metadata)
    }

    /// 错误结果
    static func error(message: String, metadata: [String: String] = [:]) -> ToolResult {
        ToolResult(output: message, isError: true, metadata: metadata)
    }

    /// 权限拒绝结果
    static func denied(reason: String) -> ToolResult {
        ToolResult(output: "Permission denied: \(reason)", isError: true, metadata: ["denied": "true"])
    }

    /// 转换为 OpenAI tool_result 格式的 content 字段
    /// AgentLoop 将此结果作为 tool_result 消息返回给 LLM
    func toToolResultContent() -> String {
        if isError {
            return "Error: \(output)"
        }
        return output
    }
}

// MARK: - Tool Result Truncator (P2-1)

/// 工具结果分层截断器 — 按工具类型采用不同截断策略
/// 在 AgentLoop 将工具结果注入 session.messages 前调用
/// - read_file/search_content: 头尾保留（文件内容头尾都有用）
/// - execute_command/run_python/run_node: 尾部保留（命令输出末尾更重要）
/// - 默认（list_directory/search_files 等）: 头部保留
enum ToolResultTruncator {
    /// 按工具名分层截断输出，超过 maxResultSize 时触发
    /// - Parameters:
    ///   - toolName: 工具名称（snake_case）
    ///   - output: 原始工具输出
    /// - Returns: 截断后的字符串（未超阈值则原样返回）
    static func truncate(toolName: String, output: String) -> String {
        let maxSize = BaizeRuntime.maxResultSize
        guard output.count > maxSize else { return output }

        switch toolName {
        case "read_file", "search_content":
            return truncateHeadAndTail(output)
        case "execute_command", "run_python", "run_node":
            return truncateTail(output)
        default:
            return truncateHead(output)
        }
    }

    /// 头尾保留截断 — 适用于文件读取/内容搜索（头部含声明，尾部含结果）
    private static func truncateHeadAndTail(_ output: String) -> String {
        let headSize = 3_000
        let tailSize = 3_000
        let head = String(output.prefix(headSize))
        let tail = String(output.suffix(tailSize))
        let truncated = output.count - headSize - tailSize
        return "\(head)\n\n[truncated \(truncated) chars]\n\n\(tail)"
    }

    /// 尾部保留截断 — 适用于命令执行（末尾含最终结果/错误信息）
    private static func truncateTail(_ output: String) -> String {
        let tailSize = 8_000
        let tail = String(output.suffix(tailSize))
        let truncated = output.count - tailSize
        return "[truncated \(truncated) chars — showing last \(tailSize) chars]\n\n\(tail)"
    }

    /// 头部保留截断 — 适用于目录列表/文件搜索（头部含主要结果）
    private static func truncateHead(_ output: String) -> String {
        let headSize = 8_000
        let head = String(output.prefix(headSize))
        let truncated = output.count - headSize
        return "\(head)\n\n[truncated \(truncated) chars]"
    }
}
