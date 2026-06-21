import Foundation

/// TodoWrite 工具 — AI 维护任务清单
///
/// AI 使用此工具创建和更新任务清单，帮助用户跟踪工作进度。
/// 不修改文件系统，仅更新内存中的 TodoItem 数组并发射 .todoUpdated 事件。
/// UI 层（TaskListView）订阅 .todoUpdated 事件显示任务清单。
struct TodoWriteTool: Tool {
    let name = "todo_write"
    let description = "创建或更新任务清单。用于跟踪复杂任务的进度。每次调用替换整个清单。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .planning

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["todos"],
        properties: [
            "todos": [
                "type": "array",
                "description": "任务列表，每次调用替换整个清单",
                "items": [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "任务内容"],
                        "status": ["type": "string", "description": "任务状态：pending/in_progress/completed", "enum": ["pending", "in_progress", "completed"]],
                        "activeForm": ["type": "string", "description": "进行中的任务描述（status 为 in_progress 时使用）"]
                    ],
                    "required": ["content", "status"]
                ]
            ]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let todosArray = input["todos"] as? [[String: Any]] else {
            return ToolResult.error(message: "缺少必填参数: todos（应为数组）")
        }

        var todoItems: [TodoItem] = []
        for (index, todoDict) in todosArray.enumerated() {
            guard let content = todoDict["content"] as? String else {
                return ToolResult.error(message: "第 \(index + 1) 个任务缺少 content 字段")
            }
            let status = todoDict["status"] as? String ?? "pending"
            let activeForm = todoDict["activeForm"] as? String

            let item = TodoItem(
                id: UUID().uuidString,
                content: activeForm ?? content,
                status: status
            )
            todoItems.append(item)
        }

        // 发射 .todoUpdated 事件（通过 context 不可直接发射，需通过 AgentLoop）
        // T03: ToolExecutionContext 不直接持有 continuation，事件通过 ToolResult.metadata 传递
        // AgentLoop 在收到 toolResult 后检查 toolName == "todo_write" 时发射 .todoUpdated
        let summary = todoItems.map { item in
            let icon: String
            switch item.status {
            case "completed": icon = "✅"
            case "in_progress": icon = "🔄"
            default: icon = "⬜"
            }
            return "\(icon) \(item.content)"
        }.joined(separator: "\n")

        return ToolResult.success(
            output: "任务清单已更新（\(todoItems.count) 项）:\n\(summary)",
            metadata: [
                "todoCount": "\(todoItems.count)",
                "toolName": "todo_write"
            ]
        )
    }
}
