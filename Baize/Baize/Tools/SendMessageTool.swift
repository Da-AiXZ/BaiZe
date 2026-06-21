import Foundation

/// SendMessage 工具 — agent 间通信
struct SendMessageTool: Tool {
    let name = "send_message"
    let description = "向团队中的其他 agent 发送消息。用于 Sub-agent 团队协作时 agent 间的直接通信。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .agent

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["recipient", "content"],
        properties: [
            "recipient": ["type": "string", "description": "接收方 agent 名称"],
            "content": ["type": "string", "description": "消息内容"],
            "summary": ["type": "string", "description": "消息摘要（5-10 个词，用于 UI 预览）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let recipient = input["recipient"] as? String, !recipient.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: recipient")
        }
        guard let content = input["content"] as? String, !content.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: content")
        }

        let summary = input["summary"] as? String ?? String(content.prefix(50))

        guard let teamCoordinator = context.teamCoordinator else {
            return ToolResult.error(message: "团队协调器未初始化")
        }

        // 发送方名称（从 context 获取或使用 "main"）
        let sender = "main"

        await teamCoordinator.sendMessage(from: sender, to: recipient, content: content)

        return ToolResult.success(
            output: "消息已发送给 '\(recipient)':\n摘要: \(summary)\n内容: \(content)",
            metadata: [
                "toolName": "send_message",
                "recipient": recipient,
                "summary": summary
            ]
        )
    }
}
