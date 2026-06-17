import Foundation

/// W11 fix: JSON Schema Dictionary 包装类型
/// [String: Any] 不是 Sendable，但在 Tool.inputSchema 场景中：
/// - inputSchema 是 let 常量，创建后永不修改
/// - 值类型只包含 String/Bool/Int/[String: Any] 等 JSON Schema 合法类型
/// - 跨 actor 隔离边界传递时，值被拷贝而非共享
/// 因此使用 @unchecked Sendable 标记为安全传递
struct JSONSchemaDictionary: @unchecked Sendable, Equatable {
    /// 内部存储的 JSON Schema 字典
    let value: [String: Any]

    /// 从普通字典创建
    init(_ value: [String: Any]) {
        self.value = value
    }

    /// 访问内部字典（便捷下标）
    subscript(key: String) -> Any? {
        value[key]
    }

    /// 用于 Equatable 比较（简化实现，比较 count 和 type 字段）
    static func == (lhs: JSONSchemaDictionary, rhs: JSONSchemaDictionary) -> Bool {
        lhs.value.count == rhs.value.count &&
        lhs.value["type"] as? String == rhs.value["type"] as? String
    }
}

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
    /// W11 fix: 改为 JSONSchemaDictionary（@unchecked Sendable），确保跨 actor 隔离边界安全传递
    var inputSchema: JSONSchemaDictionary { get }

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
/// W23 fix: 改为 class（引用语义），确保复制时共享同一服务实例
/// 由 AgentLoop 在执行工具时创建并传入
/// 包含项目路径、文件系统服务、运行时执行器、权限引擎等
/// PermissionEngine 改为 actor 后，此处持有 actor 引用（引用语义）
/// @unchecked Sendable：内部服务实例均为 class/actor（引用语义），跨隔离边界安全传递
class ToolExecutionContext: @unchecked Sendable {
    /// 项目根目录路径
    let projectPath: String

    /// 文件系统服务（class 引用类型 — 共享同一实例）
    let fileSystemService: FileSystemService

    /// 运行时执行器（class 引用类型）
    let runtimeExecutor: RuntimeExecutor

    /// 权限引擎（actor 引用类型 — 共享同一实例，权限变更即时传播）
    let permissionEngine: PermissionEngine

    /// W23 fix: 初始化器注入共享服务实例
    init(
        projectPath: String,
        fileSystemService: FileSystemService,
        runtimeExecutor: RuntimeExecutor,
        permissionEngine: PermissionEngine
    ) {
        self.projectPath = projectPath
        self.fileSystemService = fileSystemService
        self.runtimeExecutor = runtimeExecutor
        self.permissionEngine = permissionEngine
    }

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
    /// W11 fix: inputSchema 现在是 JSONSchemaDictionary，toDefinition 提取 .value
    func toDefinition() -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: inputSchema.value
        )
    }
}

// MARK: - Common Input Schema Helpers

/// 常用 JSON Schema 构建辅助函数
/// W11 fix: 返回 JSONSchemaDictionary（@unchecked Sendable）而非 [String: Any]
enum SchemaBuilder {

    /// 构建基础 JSON Schema（type: object, required fields）
    static func objectSchema(
        required: [String] = [],
        properties: [String: [String: Any]]
    ) -> JSONSchemaDictionary {
        return JSONSchemaDictionary([
            "type": "object",
            "required": required,
            "properties": properties,
        ])
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