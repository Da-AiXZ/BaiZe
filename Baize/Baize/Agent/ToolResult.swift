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
        // 截断过长输出
        self.output = output.truncated(to: BaizeRuntime.maxResultSize)
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