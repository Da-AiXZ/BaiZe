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

// MARK: - Tool Permission Level

/// 工具权限级别 — 声明工具的默认权限策略
/// 权限引擎结合 permissionLevel 和运行时 needsPermission() 综合决策
enum ToolPermissionLevel: Sendable {
    /// 只读工具 — 自动允许（read_file, list_directory, search_content 等）
    case autoAllow
    /// 写操作工具 — 需要用户确认（write_file, edit_file, execute_command 等）
    case askUser
    /// 高危工具 — 默认拒绝，需用户显式批准（delete_file, 特殊操作等）
    case denyByDefault
}

// MARK: - Tool Category

/// 工具分类 — 用于按类别查询工具列表
/// ToolRegistry.getToolsByCategory() 按此枚举过滤
enum ToolCategory: Sendable {
    case fileSystem   // 文件系统工具（read_file, write_file, edit_file, list_directory, search_files, search_content, delete_file）
    case execution    // 运行时工具（execute_command, run_node, run_python）
    case web          // 网络工具（web_search, web_fetch）
    case agent        // 子 agent 工具（agent, send_message）
    case task         // 任务管理工具（task_create, task_update, task_list, task_get）
    case skill        // 技能工具（skill）
    case mcp          // MCP 工具（mcp_tool_call）
    case planning     // 规划工具（todo_write, enter_plan_mode, exit_plan_mode, ask_user_question）
}

// MARK: - Tool Permission Decision

/// 工具运行时权限决策 — Tool.needsPermission() 返回值
/// 注意：命名为 ToolPermissionDecision 以避免与 PermissionEngine.PermissionDecision（struct）冲突
/// PermissionEngine 的 PermissionDecision 是最终权威决策（含 effect + reason）
/// ToolPermissionDecision 是工具自评估（供 PermissionEngine 参考）
enum ToolPermissionDecision: Sendable {
    /// 允许执行
    case allow
    /// 需要用户确认，携带原因
    case ask(reason: String)
    /// 拒绝执行，携带原因
    case deny(reason: String)
}

/// Tool 协议定义 — 所有工具实现此协议
/// 定义工具的名称、描述、输入 Schema、读写属性、执行方法
/// ToolRegistry 根据名称查找并调用对应 Tool 实例
/// Phase 1: 10 个工具实现此协议（7 文件工具 + 3 运行时工具）
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

// MARK: - Tool Protocol Extensions (R1 扩展 — 现有工具零改动)

/// R1 扩展：Tool 协议新增属性和方法，通过 protocol extension 提供默认值
/// 现有 10 个工具无需任何修改即可编译通过（自动获得默认实现）
extension Tool {
    /// 工具权限级别 — 声明工具的默认权限策略
    /// 默认 .askUser（写操作），只读工具应覆写为 .autoAllow，高危工具应覆写为 .denyByDefault
    var permissionLevel: ToolPermissionLevel { .askUser }

    /// 工具分类 — 用于按类别查询
    /// 默认 .fileSystem，各工具应覆写为正确的分类
    var category: ToolCategory { .fileSystem }

    /// 运行时权限判断 — 根据输入参数和上下文动态决策
    /// 默认实现基于 isReadOnly/isDestructive 判断：
    /// - 只读工具 → .allow
    /// - 高危工具 → .deny(reason)
    /// - 其他 → .ask(reason)
    /// 工具可覆写此方法实现更精细的运行时权限控制
    func needsPermission(input: [String: Any], context: ToolExecutionContext) -> ToolPermissionDecision {
        if isReadOnly {
            return .allow
        }
        if isDestructive {
            return .deny(reason: "\(name) 是危险操作，需要用户确认")
        }
        return .ask(reason: "\(name) 将修改系统状态，需要用户确认")
    }

    /// 工具是否可用 — 某些工具可能依赖特定运行时或服务
    /// 默认 true（可用），工具可覆写以检查运行时依赖
    /// 例如 WebSearchTool 需检查 webSearchProvider 是否存在
    func isAvailable(context: ToolExecutionContext) -> Bool {
        true
    }
}

// MARK: - Tool Execution Context

/// 工具执行上下文 — 传入工具执行所需的共享服务
/// W23 fix: 改为 class（引用语义），确保复制时共享同一服务实例
/// 由 AgentLoop 在执行工具时创建并传入
/// 包含项目路径、文件系统服务、运行时执行器、权限引擎等
/// R1 扩展：新增 apiGateway/memoryStore/skillRegistry/taskList/planModeState/webSearchProvider/commandRegistry/workingDirectory 可选属性
/// 所有新增属性为可选（?），现有 10 个工具不受影响（它们只用 projectPath/fileSystemService/runtimeExecutor/permissionEngine）
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

    // MARK: - R1 扩展属性（全部可选，现有工具零影响）

    /// API Gateway — 供 WebFetchTool/WebSearchTool 等调 LLM 摘要/搜索
    let apiGateway: APIGateway?

    /// Memory 存储 — 供 MemoryExtractor 在会话结束时提取记忆
    let memoryStore: MemoryStore?

    /// Skills 注册表 — 供 SkillTool 调用已安装技能
    let skillRegistry: SkillRegistry?

    /// 共享任务列表 — 供 Task 系列 CRUD 工具操作
    let taskList: TaskList?

    /// PlanMode 状态机 — 供 EnterPlanMode/ExitPlanMode 工具管理规划状态
    let planModeState: PlanModeState?

    /// 网络搜索 Provider — 供 WebSearchTool 执行搜索
    let webSearchProvider: WebSearchProvider?

    /// Slash 命令注册表 — 供命令解析和处理
    let commandRegistry: CommandRegistry?

    /// R2 新增：团队协调器 — 供 AgentTool/SendMessageTool 管理子 agent
    let teamCoordinator: TeamCoordinator?

    /// R2 新增：MCP 连接管理器 — 供 MCPTool 调用远程 MCP server 工具
    let mcpManager: MCPManager?

    /// R2 新增：共享 ToolRegistry — 供 AgentTool 创建子 agent 时传递
    let toolRegistry: ToolRegistry?

    /// R3 新增：GitService — 供 ExecuteCommandTool 拦截 git 命令转给 libgit2
    let gitService: GitService?

    /// 工作目录（可区别于 projectPath，多子项目场景使用）
    /// A7 决策：当前 projectPath 即工作目录，此属性预留扩展
    let workingDirectory: String?

    /// W23 fix: 初始化器注入共享服务实例
    /// R1 扩展：新增可选参数，全部带默认值 nil，现有调用点零改动
    init(
        projectPath: String,
        fileSystemService: FileSystemService,
        runtimeExecutor: RuntimeExecutor,
        permissionEngine: PermissionEngine,
        apiGateway: APIGateway? = nil,
        memoryStore: MemoryStore? = nil,
        skillRegistry: SkillRegistry? = nil,
        taskList: TaskList? = nil,
        planModeState: PlanModeState? = nil,
        webSearchProvider: WebSearchProvider? = nil,
        commandRegistry: CommandRegistry? = nil,
        workingDirectory: String? = nil,
        teamCoordinator: TeamCoordinator? = nil,
        mcpManager: MCPManager? = nil,
        toolRegistry: ToolRegistry? = nil,
        gitService: GitService? = nil
    ) {
        self.projectPath = projectPath
        self.fileSystemService = fileSystemService
        self.runtimeExecutor = runtimeExecutor
        self.permissionEngine = permissionEngine
        self.apiGateway = apiGateway
        self.memoryStore = memoryStore
        self.skillRegistry = skillRegistry
        self.taskList = taskList
        self.planModeState = planModeState
        self.webSearchProvider = webSearchProvider
        self.commandRegistry = commandRegistry
        self.workingDirectory = workingDirectory
        self.teamCoordinator = teamCoordinator
        self.mcpManager = mcpManager
        self.toolRegistry = toolRegistry
        self.gitService = gitService
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