import Foundation

/// TaskList 工具 — 列出共享任务列表中的所有任务
struct TaskListTool: Tool {
    let name = "task_list"
    let description = "列出团队共享任务列表中的所有任务。可按状态过滤。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .task

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: [],
        properties: [
            "status": ["type": "string", "description": "按状态过滤（可选）：pending/inProgress/completed", "enum": ["pending", "inProgress", "completed"]]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let taskList = context.taskList else {
            return ToolResult.error(message: "任务列表未初始化")
        }

        let allTasks = await taskList.list()

        // 可选状态过滤
        let filteredTasks: [TaskItem]
        if let statusString = input["status"] as? String,
           let status = TaskStatus(rawValue: statusString) {
            filteredTasks = allTasks.filter { $0.status == status }
        } else {
            filteredTasks = allTasks
        }

        if filteredTasks.isEmpty {
            return ToolResult.success(
                output: "暂无任务" + (input["status"] != nil ? "（状态: \(input["status"] as? String ?? "")）" : ""),
                metadata: ["toolName": "task_list", "taskCount": "0"]
            )
        }

        let taskLines = filteredTasks.enumerated().map { index, task in
            let statusIcon: String
            switch task.status {
            case .completed: statusIcon = "✅"
            case .inProgress: statusIcon = "🔄"
            case .pending: statusIcon = "⬜"
            case .deleted: statusIcon = "🗑️"
            }
            return "[\(index + 1)] \(statusIcon) \(task.subject) (id=\(task.id.uuidString.prefix(8)), owner=\(task.owner ?? "未分配"))"
        }.joined(separator: "\n")

        return ToolResult.success(
            output: "共 \(filteredTasks.count) 个任务:\n\(taskLines)",
            metadata: ["toolName": "task_list", "taskCount": "\(filteredTasks.count)"]
        )
    }
}
