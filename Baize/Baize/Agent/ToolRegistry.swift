import Foundation

/// 工具注册表 — 管理所有工具的注册、查找和执行
/// AgentLoop 通过 ToolRegistry 根据 tool_call.name 查找对应 Tool 实例
/// Phase 1 注册 9 个内置工具（6 文件工具 + 3 运行时工具）
actor ToolRegistry {

    // MARK: - Properties

    /// 工具注册表：工具名称 → Tool 实例
    private var tools: [String: Tool] = [:]

    // MARK: - Initialization

    /// W22 fix: 接受注入的 FileSystemService 和 RuntimeExecutor
    /// 避免在 registerDefaultTools 中创建新的独立实例
    init(fileSystemService: FileSystemService? = nil, runtimeExecutor: RuntimeExecutor? = nil) {
        registerDefaultTools(fileSystemService: fileSystemService, runtimeExecutor: runtimeExecutor)
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

    // MARK: - Default Tool Registration

    /// 注册 Phase 1 默认 9 个工具
    /// W22 fix: 使用注入的共享服务实例，避免创建独立实例导致状态丢失
    private func registerDefaultTools(fileSystemService: FileSystemService?, runtimeExecutor: RuntimeExecutor?) {
        let fsService = fileSystemService ?? FileSystemService()
        let runtime = runtimeExecutor ?? RuntimeExecutor()

        // 文件操作工具（6 个）
        register(tool: ReadFileTool(fileSystemService: fsService))
        register(tool: WriteFileTool(fileSystemService: fsService))
        register(tool: EditFileTool(fileSystemService: fsService))
        register(tool: ListDirectoryTool(fileSystemService: fsService))
        register(tool: SearchFilesTool(fileSystemService: fsService))
        register(tool: SearchContentTool(fileSystemService: fsService))

        // 运行时执行工具（3 个）
        register(tool: ExecuteCommandTool(runtimeExecutor: runtime))
        register(tool: RunNodeTool(runtimeExecutor: runtime))
        register(tool: RunPythonTool(runtimeExecutor: runtime))

        toolLogger.info("Default 9 tools registered")
    }
}