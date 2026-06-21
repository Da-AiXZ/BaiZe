import Foundation

/// TaskUpdate 工具 — 更新共享任务列表中的任务状态
struct TaskUpdateTool: Tool {
    let name = "task_update"
    let description = "更新团队共享任务列表中的任务状态或所有者。用于标记任务进度或重新分配任务。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .task

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["taskId"],
        properties: [
            "taskId": ["type": "string", "description": "任务 ID（UUID 字符串）"],
            "status": ["type": "string", "description": "新状态：pending/inProgress/completed/deleted", "enum": ["pending", "inProgress", "completed", "deleted"]],
            "owner": ["type": "string", "description": "新所有者 agent 名称（可选）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let taskIdString = input["taskId"] as? String, !taskIdString.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: taskId")
        }

        let statusString = input["status"] as? String
        let owner = input["owner"] as? String

        guard let taskList = context.taskList else {
            return ToolResult.error(message: "任务列表未初始化")
        }

        var status: TaskStatus? = nil
        if let s = statusString {
            status = TaskStatus(rawValue: s)
            if status == nil {
                return ToolResult.error(message: "无效的状态值: \(s)。有效值: pending/inProgress/completed/deleted")
            }
        }

        guard let updatedTask = await taskList.update(taskIdString: taskIdString, status: status, owner: owner) else {
            return ToolResult.error(message: "未找到任务: \(taskIdString)")
        }

        return ToolResult.success(
            output: "任务已更新:\n- ID: \(updatedTask.id)\n- 标题: \(updatedTask.subject)\n- 状态: \(updatedTask.status.rawValue)\n- 所有者: \(updatedTask.owner ?? "未分配")",
            metadata: [
                "toolName": "task_update",
                "taskId": updatedTask.id.uuidString,
                "taskStatus": updatedTask.status.rawValue
            ]
        )
    }
}
