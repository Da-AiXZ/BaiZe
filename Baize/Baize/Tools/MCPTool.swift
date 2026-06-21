import Foundation

/// MCP 工具 — 调用 MCP server 的远程工具
struct MCPTool: Tool {
    let name = "mcp_tool_call"
    let description = "调用远程 MCP server 的工具。MCP (Model Context Protocol) 允许接入外部工具生态。使用前需在设置中配置 MCP server。"
    let isReadOnly = false
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .askUser
    let category: ToolCategory = .mcp

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["serverId", "toolName"],
        properties: [
            "serverId": ["type": "string", "description": "MCP server ID"],
            "toolName": ["type": "string", "description": "要调用的工具名称"],
            "args": ["type": "object", "description": "工具参数（JSON 对象）"]
        ]
    )

    func isAvailable(context: ToolExecutionContext) -> Bool {
        context.mcpManager != nil
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let serverId = input["serverId"] as? String, !serverId.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: serverId")
        }
        guard let toolName = input["toolName"] as? String, !toolName.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: toolName")
        }

        let args = input["args"] as? [String: Any] ?? [:]

        guard let mcpManager = context.mcpManager else {
            return ToolResult.error(message: "MCP 管理器未初始化。请在设置中配置 MCP server。")
        }

        // 检查是否已连接
        let connected = await mcpManager.isConnected(serverId: serverId)
        if !connected {
            // 尝试自动连接（如果配置存在）
            let servers = await mcpManager.listServers()
            guard let config = servers.first(where: { $0.id == serverId }) else {
                return ToolResult.error(message: "未找到 MCP server 配置: \(serverId)")
            }

            do {
                try await mcpManager.connect(config: config)
            } catch {
                return ToolResult.error(message: "连接 MCP server 失败: \(error.localizedDescription)")
            }
        }

        // 调用工具
        do {
            let result = try await mcpManager.callTool(serverId: serverId, name: toolName, args: args)

            return ToolResult.success(
                output: result,
                metadata: [
                    "toolName": "mcp_tool_call",
                    "serverId": serverId,
                    "mcpToolName": toolName
                ]
            )
        } catch {
            return ToolResult.error(message: "MCP 工具调用失败: \(error.localizedDescription)")
        }
    }
}
