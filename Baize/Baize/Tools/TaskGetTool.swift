import Foundation

/// TaskGet 工具 — 获取任务详情
struct TaskGetTool: Tool {
    let name = "task_get"
    let description = "获取团队共享任务列表中指定任务的详细信息。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .task

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["taskId"],
        properties: [
            "taskId": ["type": "string", "description": "任务 ID（UUID 字符串）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let taskIdString = input["taskId"] as? String, !taskIdString.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: taskId")
        }

        guard let taskList = context.taskList else {
            return ToolResult.error(message: "任务列表未初始化")
        }

        guard let task = await taskList.get(taskIdString: taskIdString) else {
            return ToolResult.error(message: "未找到任务: \(taskIdString)")
        }

        let blocksStr = task.blocks.isEmpty ? "无" : task.blocks.map { $0.uuidString.prefix(8).description }.joined(separator: ", ")
        let blockedByStr = task.blockedBy.isEmpty ? "无" : task.blockedBy.map { $0.uuidString.prefix(8).description }.joined(separator: ", ")

        let detail = """
        任务详情:
        - ID: \(task.id)
        - 标题: \(task.subject)
        - 描述: \(task.description)
        - 状态: \(task.status.rawValue)
        - 所有者: \(task.owner ?? "未分配")
        - 阻塞任务: \(blocksStr)
        - 被阻塞: \(blockedByStr)
        - 创建时间: \(task.createdAt)
        """

        return ToolResult.success(
            output: detail,
            metadata: [
                "toolName": "task_get",
                "taskId": task.id.uuidString
            ]
        )
    }
}
