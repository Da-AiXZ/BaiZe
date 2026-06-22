import Foundation

/// Agent 工具 — spawn 子 agent 执行独立任务
///
/// AI 使用此工具启动子 agent 处理子任务。
/// 子 agent 拥有独立的 ConversationSession，共享 ToolRegistry，
/// 使用 .plan 权限模式（仅只读工具）。
/// 子 agent 完成后返回最终文本结果。
struct AgentTool: Tool {
    let name = "agent"
    let description = "启动子 agent 执行独立任务。子 agent 拥有独立会话，可并行处理子任务。完成后返回最终结果。适用于需要长时间运行或可并行化的子任务。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .agent

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["description"],
        properties: [
            "description": ["type": "string", "description": "分配给子 agent 的任务描述"],
            "subagent_type": ["type": "string", "description": "子 agent 类型（如 general-purpose, researcher, coder），默认 general-purpose", "default": "general-purpose"],
            "name": ["type": "string", "description": "子 agent 名称（可选，用于团队中标识）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let taskDescription = input["description"] as? String, !taskDescription.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: description（任务描述）")
        }

        let subagentType = input["subagent_type"] as? String ?? "general-purpose"
        let agentName = input["name"] as? String ?? "agent-\(UUID().uuidString.prefix(8))"

        // 获取 TeamCoordinator
        guard let teamCoordinator = context.teamCoordinator else {
            return ToolResult.error(message: "团队协调器未初始化，无法创建子 agent")
        }

        // 获取共享服务（从 context 中获取）
        guard let apiGateway = context.apiGateway,
              let toolRegistry = context.toolRegistry else {
            return ToolResult.error(message: "API 网关或工具注册表未初始化")
        }

        // 创建子 agent 的 PermissionEngine
        // P0-4 fix: 使用 .default 模式而非 .plan 模式
        // .plan 模式只允许只读工具，导致子 agent 的 AgentTool/SendMessage/TaskCreate 等写操作被拒
        // 子 agent 应继承父 agent 的权限策略，使用 .default 模式
        let subPermissionEngine = PermissionEngine(mode: .default)

        // 创建子 agent 的 ConversationSession
        let subSession = ConversationSession(projectPath: context.projectPath)

        // 创建子 agent 的 ContextManager（独立，但共享 ProjectContext 的根路径）
        // 子 agent 不注入 memoryStore（避免记忆污染）
        let subContextManager = ContextManager(
            projectContext: ProjectContext(rootPath: context.projectPath, fileSystemService: context.fileSystemService),
            apiGateway: apiGateway,
            memoryStore: nil
        )

        // 创建子 AgentLoop（共享 ToolRegistry，独立 session + 独立 PermissionEngine）
        let subLoop = await teamCoordinator.spawnTeammate(
            name: agentName,
            subagentType: subagentType,
            agentLoopFactory: {
                AgentLoop(
                    apiGateway: apiGateway,
                    toolRegistry: toolRegistry,
                    permissionEngine: subPermissionEngine,
                    contextManager: subContextManager,
                    conversationStore: ConversationStore(),
                    fileSystemService: context.fileSystemService,
                    runtimeExecutor: context.runtimeExecutor,
                    skillRegistry: context.skillRegistry,
                    memoryStore: nil,
                    commandRegistry: nil,
                    planModeState: context.planModeState,
                    webSearchProvider: context.webSearchProvider,
                    session: subSession
                )
            }
        )

        // 运行子 agent 并收集最终文本
        do {
            let eventStream = await subLoop.run(userMessage: taskDescription)

            var finalText = ""
            for try await event in eventStream {
                switch event {
                case .textDelta(let text):
                    finalText += text
                case .completed:
                    break
                case .error(let error):
                    return ToolResult.error(message: "子 agent 执行错误: \(error.localizedDescription)")
                default:
                    break
                }
            }

            if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalText = "子 agent 完成了任务，但未返回文本结果。"
            }

            return ToolResult.success(
                output: "子 agent '\(agentName)' 完成任务:\n\n\(finalText)",
                metadata: [
                    "agentName": agentName,
                    "subagentType": subagentType,
                    "toolName": "agent"
                ]
            )
        } catch {
            return ToolResult.error(message: "子 agent 执行失败: \(error.localizedDescription)")
        }
    }
}
