import Foundation

/// Tool 协议定义 — 所有工具实现此协议
/// 定义工具的名称、描述、输入 Schema、读写属性、执行方法
/// ToolRegistry 根据名称查找并调用对应 Tool 实例
/// Phase 1: 9 个工具实现此协议（6 文件工具 + 3 运行时工具）
protocol Tool: Sendable {
    /// 工具名称（snake_case 格式，与 OpenAI function calling name 对应）
    var name: String { get }

    /// 工具描述（供 LLM 理解工具用途，出现在 function calling description 中）
    var description: String { get }

    /// 输入参数 JSON Schema（OpenAI function calling parameters 格式）
    /// 定义工具接受的参数名称、类型、是否必填、描述
    var inputSchema: [String: Any] { get }

    /// 是否为只读工具（不修改文件系统状态）
    /// 只读工具在权限引擎中自动 allow
    var isReadOnly: Bool { get }

    /// 是否为危险操作（可能造成不可逆影响）
    /// 危险工具在权限引擎中需要 ask 或 deny
    var isDestructive: Bool { get }

    /// 执行工具操作
    /// - Parameters:
    ///   - input: 工具参数字典（由 LLM 生成的 JSON 解析而来）
    ///   - context: 工具执行上下文（项目路径、运行时服务等）
    /// - Returns: ToolResult（成功或错误）
    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult
}

// MARK: - Tool Execution Context

/// 工具执行上下文 — 传入工具执行所需的共享服务
/// 由 AgentLoop 在执行工具时创建并传入
/// 包含项目路径、文件系统服务、运行时执行器、权限引擎等
/// 修复 C7/C8：PermissionEngine 和 FileSystemService 改为 class 后，
/// 此 struct 仍可持有引用（class 实例是引用语义，值拷贝共享同一实例）
struct ToolExecutionContext: Sendable {
    /// 项目根目录路径
    let projectPath: String

    /// 文件系统服务（class 引用类型 — 共享同一实例）
    let fileSystemService: FileSystemService

    /// 运行时执行器（class 引用类型）
    let runtimeExecutor: RuntimeExecutor

    /// 权限引擎（class 引用类型 — 共享同一实例，权限变更即时传播）
    let permissionEngine: PermissionEngine

    // MARK: - Convenience Paths

    /// 解析为绝对路径（如果 input 中的路径是相对路径，补全为项目根目录下的完整路径）
    func resolvePath(_ inputPath: String) -> String {
        if inputPath.hasPrefix("/") {
            return inputPath // 已经是绝对路径
        }
        return (projectPath as NSString).appendingPathComponent(inputPath)
    }
}

// MARK: - Tool Definition Builder

/// Tool 协议扩展 — 自动构建 OpenAI function calling 格式的 ToolDefinition
extension Tool {
    /// 生成 OpenAI tools 参数格式的 ToolDefinition
    func toDefinition() -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: inputSchema
        )
    }
}

// MARK: - Common Input Schema Helpers

/// 常用 JSON Schema 构建辅助函数
enum SchemaBuilder {

    /// 构建基础 JSON Schema（type: object, required fields）
    static func objectSchema(
        required: [String] = [],
        properties: [String: [String: Any]]
    ) -> [String: Any] {
        return [
            "type": "object",
            "required": required,
            "properties": properties,
        ]
    }

    /// 字符串参数 Schema
    static func stringProperty(description: String) -> [String: Any] {
        return ["type": "string", "description": description]
    }

    /// 整数参数 Schema
    static func integerProperty(description: String) -> [String: Any] {
        return ["type": "integer", "description": description]
    }

    /// 布尔参数 Schema
    static func booleanProperty(description: String, defaultValue: Bool? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "boolean", "description": description]
        if let defaultVal = defaultValue {
            schema["default"] = defaultVal
        }
        return schema
    }

    /// 文件路径参数 Schema（常用）
    static func pathProperty(description: String = "文件路径（绝对路径或项目相对路径）") -> [String: Any] {
        stringProperty(description: description)
    }
}