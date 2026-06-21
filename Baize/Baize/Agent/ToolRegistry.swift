import Foundation

/// 工具注册表 — 管理所有工具的注册、查找和执行
/// AgentLoop 通过 ToolRegistry 根据 tool_call.name 查找对应 Tool 实例
/// Phase 1 注册 10 个内置工具（7 文件工具 + 3 运行时工具）
actor ToolRegistry {

    // MARK: - Properties

    /// 工具注册表：工具名称 → Tool 实例
    private var tools: [String: Tool] = [:]

    // MARK: - Initialization

    /// W22 fix: 接受注入的 FileSystemService、RuntimeExecutor 和 NodeRuntimeEngine
    /// Swift 6 模式下 actor init 是 nonisolated，不能调 actor-isolated 方法
    /// 改用 static 工厂方法构建工具字典，init 直接赋值给 self.tools
    /// nodeEngine/pythonEngine 参数用于未来扩展（当前 RuntimeExecutor 已封装策略）
    init(fileSystemService: FileSystemService? = nil, runtimeExecutor: RuntimeExecutor? = nil, nodeEngine: NodeRuntimeEngine? = nil, pythonEngine: PythonRuntimeEngine? = nil) {
        self.tools = Self.buildDefaultTools(
            fs: fileSystemService ?? FileSystemService(rootPath: BaizePath.projectRoot),
            rt: runtimeExecutor ?? RuntimeExecutor(),
            nodeEngine: nodeEngine,
            pythonEngine: pythonEngine
        )
    }

    /// 静态工厂 — 构建默认工具字典，供 init 使用
    /// Swift 6 模式下 actor init 不能直接调 actor-isolated 方法
    private static func buildDefaultTools(fs: FileSystemService, rt: RuntimeExecutor, nodeEngine: NodeRuntimeEngine?, pythonEngine: PythonRuntimeEngine?) -> [String: Tool] {
        var tools: [String: Tool] = [:]
        // 文件操作工具 (7 个)
        let readFile = ReadFileTool(fileSystemService: fs);    tools[readFile.name] = readFile
        let writeFile = WriteFileTool(fileSystemService: fs);  tools[writeFile.name] = writeFile
        let editFile = EditFileTool(fileSystemService: fs);    tools[editFile.name] = editFile
        let listDir = ListDirectoryTool(fileSystemService: fs); tools[listDir.name] = listDir
        let searchFiles = SearchFilesTool(fileSystemService: fs); tools[searchFiles.name] = searchFiles
        let searchContent = SearchContentTool(fileSystemService: fs); tools[searchContent.name] = searchContent
        let deleteFile = DeleteFileTool(fileSystemService: fs); tools[deleteFile.name] = deleteFile
        // 运行时工具 (3 个)
        let execCmd = ExecuteCommandTool(runtimeExecutor: rt);  tools[execCmd.name] = execCmd
        let runNode = RunNodeTool(runtimeExecutor: rt);         tools[runNode.name] = runNode
        let runPython = RunPythonTool(runtimeExecutor: rt);     tools[runPython.name] = runPython
        // R1 新增工具 (7 个) — 无需注入依赖，通过 ToolExecutionContext 访问
        let todoWrite = TodoWriteTool();                       tools[todoWrite.name] = todoWrite
        let askUser = AskUserQuestionTool();                   tools[askUser.name] = askUser
        let webFetch = WebFetchTool();                         tools[webFetch.name] = webFetch
        let webSearch = WebSearchTool();                       tools[webSearch.name] = webSearch
        let enterPlan = EnterPlanModeTool();                   tools[enterPlan.name] = enterPlan
        let exitPlan = ExitPlanModeTool();                     tools[exitPlan.name] = exitPlan
        let skill = SkillTool();                               tools[skill.name] = skill
        // R2 新增工具 (7 个) — Sub-agent + MCP
        let agent = AgentTool();                               tools[agent.name] = agent
        let taskCreate = TaskCreateTool();                     tools[taskCreate.name] = taskCreate
        let taskUpdate = TaskUpdateTool();                     tools[taskUpdate.name] = taskUpdate
        let taskListTool = TaskListTool();                     tools[taskListTool.name] = taskListTool
        let taskGet = TaskGetTool();                           tools[taskGet.name] = taskGet
        let sendMessage = SendMessageTool();                   tools[sendMessage.name] = sendMessage
        let mcpTool = MCPTool();                               tools[mcpTool.name] = mcpTool
        return tools
    }

    // MARK: - Registration

    /// 注册工具
    func register(tool: Tool) {
        tools[tool.name] = tool
        toolLogger.info("Tool registered: \(tool.name)")
    }

    /// 批量注册工具
    func registerAll(toolList: [Tool]) {
        for tool in toolList {
            register(tool: tool)
        }
    }

    /// 注销工具
    func unregister(name: String) {
        tools.removeValue(forKey: name)
        toolLogger.info("Tool unregistered: \(name)")
    }

    // MARK: - Execution

    /// 执行工具调用 — 根据 tool_call.name 查找并调用对应 Tool
    /// - Parameters:
    ///   - toolCall: LLM 返回的 ToolCall（包含 name 和 arguments）
    ///   - context: 工具执行上下文
    /// - Returns: ToolResult
    func execute(toolCall: ToolCall, context: ToolExecutionContext) async -> ToolResult {
        guard let tool = tools[toolCall.name] else {
            toolLogger.error("Unknown tool: \(toolCall.name)")
            return ToolResult.error(message: "Unknown tool: \(toolCall.name)")
        }

        let input = toolCall.parsedArguments()
        toolLogger.info("Executing tool: \(tool.name) with args: \(input)")

        let result = await tool.execute(input: input, context: context)
        toolLogger.info("Tool result: \(tool.name) — \(result.isError ? "error" : "success")")
        return result
    }

    // MARK: - Tool Definitions

    /// 获取所有已注册工具的 OpenAI function calling 定义
    /// 用于构建 LLM 请求的 tools 参数
    func getToolDefinitions() -> [ToolDefinition] {
        tools.values.map { $0.toDefinition() }
    }

    /// 获取已注册工具名称列表
    func getToolNames() -> [String] {
        tools.keys.sorted()
    }

    /// 检查工具是否已注册
    func hasTool(name: String) -> Bool {
        tools[name] != nil
    }

    // MARK: - R1 扩展：工具查询

    /// 获取工具实例 — 供 PermissionEngine 动态查询工具属性
    /// R1 新增：PermissionEngine.findTool() 通过此方法查询 Tool 实例，
    /// 替代之前的硬编码 ToolInfo 列表
    /// - Parameter name: 工具名称
    /// - Returns: Tool 实例（如果已注册）
    func getTool(name: String) -> Tool? {
        tools[name]
    }

    /// 按分类获取工具列表 — 供 AgentLoop 动态过滤可用工具
    /// R1 新增：支持按 ToolCategory 查询工具（如只查 .planning 类工具）
    /// - Parameter category: 工具分类
    /// - Returns: 该分类下所有已注册工具
    func getToolsByCategory(_ category: ToolCategory) -> [Tool] {
        tools.values.filter { $0.category == category }
    }

    /// 获取所有可用工具（通过 isAvailable 过滤）
    /// R1 新增：某些工具可能依赖特定运行时或服务（如 WebSearchTool 需 webSearchProvider）
    /// AgentLoop 构建工具定义列表时调用此方法，只向 LLM 发送可用工具
    /// - Parameter context: 工具执行上下文（用于检查服务依赖）
    /// - Returns: 所有已注册且可用的工具
    func getAvailableTools(context: ToolExecutionContext) -> [Tool] {
        tools.values.filter { $0.isAvailable(context: context) }
    }

}