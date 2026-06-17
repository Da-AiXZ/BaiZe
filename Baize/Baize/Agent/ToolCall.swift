import Foundation

/// 工具调用模型 — LLM 返回的 function calling 调用请求
/// 包含：调用 ID（用于匹配 tool_result）、工具名称、参数 JSON
/// 与 OpenAI Chat Completions API 的 tool_call 格式对应
struct ToolCall: Sendable, Identifiable, Codable, Equatable {
    /// 工具调用唯一 ID（由 LLM 分配，用于匹配 tool_result）
    let id: String

    /// 工具名称（snake_case，如 "read_file", "execute_command"）
    let name: String

    /// 工具参数（JSON 字符串，由 LLM 生成）
    /// 需要在执行前解析为 [String: Any]
    let arguments: String

    // MARK: - Initialization

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    // MARK: - Argument Parsing

    /// 将 arguments JSON 字符串解析为字典
    /// - Returns: 解析后的参数字典，解析失败返回空字典
    func parsedArguments() -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            toolLogger.error("ToolCall arguments UTF8 conversion failed: \(id)")
            return [:]
        }

        do {
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return parsed ?? [:]
        } catch {
            toolLogger.error("ToolCall arguments JSON parse error: \(error.localizedDescription)")
            return [:]
        }
    }

    /// 获取参数中指定键的字符串值
    /// - Parameter key: 参数键名
    /// - Returns: 对应的字符串值，不存在时返回 nil
    func argumentString(for key: String) -> String? {
        parsedArguments()[key] as? String
    }

    /// 获取参数中指定键的整数值
    /// - Parameter key: 参数键名
    /// - Returns: 对应的整数值，不存在时返回 nil
    func argumentInt(for key: String) -> Int? {
        parsedArguments()[key] as? Int
    }

    /// 获取参数中指定键的布尔值
    /// - Parameter key: 参数键名
    /// - Returns: 对应的布尔值，不存在时返回 nil
    func argumentBool(for key: String) -> Bool? {
        parsedArguments()[key] as? Bool
    }

    // MARK: - Equality

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}