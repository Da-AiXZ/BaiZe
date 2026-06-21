import Foundation

/// TaskCreate 工具 — 创建新任务到共享任务列表
struct TaskCreateTool: Tool {
    let name = "task_create"
    let description = "创建新任务到团队共享任务列表。用于 Sub-agent 团队协作时分配和跟踪任务。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .task

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["subject", "description"],
        properties: [
            "subject": ["type": "string", "description": "任务标题（简短的祈使句）"],
            "description": ["type": "string", "description": "任务详细描述（包含上下文和验收标准）"],
            "owner": ["type": "string", "description": "任务所有者 agent 名称（可选）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let subject = input["subject"] as? String, !subject.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: subject")
        }
        guard let description = input["description"] as? String, !description.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: description")
        }

        let owner = input["owner"] as? String

        guard let taskList = context.taskList else {
            return ToolResult.error(message: "任务列表未初始化")
        }

        let task = await taskList.create(subject: subject, description: description, owner: owner)

        return ToolResult.success(
            output: "任务已创建:\n- ID: \(task.id)\n- 标题: \(task.subject)\n- 描述: \(task.description)\n- 状态: \(task.status.rawValue)\n- 所有者: \(task.owner ?? "未分配")",
            metadata: [
                "toolName": "task_create",
                "taskId": task.id.uuidString,
                "taskSubject": task.subject
            ]
        )
    }
}
