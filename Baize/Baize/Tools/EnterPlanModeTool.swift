import Foundation

/// EnterPlanMode 工具 — 进入计划模式
///
/// AI 使用此工具进入计划模式。在计划模式下，AI 只能做只读操作（read_file/list_directory/search 等），
/// 禁止写操作（write_file/edit_file/execute_command 等）。
/// AI 收集信息并制定计划后，使用 ExitPlanModeTool 提交计划等待用户审批。
struct EnterPlanModeTool: Tool {
    let name = "enter_plan_mode"
    let description = "进入计划模式。在计划模式下，AI 只能进行只读操作（查看文件、搜索等），不能修改文件或执行命令。用于复杂任务的规划阶段。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .planning

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: [],
        properties: [
            "reason": ["type": "string", "description": "进入计划模式的原因（可选）"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let planModeState = context.planModeState else {
            return ToolResult.error(message: "PlanMode 状态机未初始化")
        }

        await planModeState.enter()

        return ToolResult.success(
            output: "已进入计划模式。在此模式下，你只能进行只读操作（read_file, list_directory, search_files, search_content, web_search, web_fetch）。制定好计划后，使用 exit_plan_mode 工具提交计划等待用户审批。",
            metadata: ["toolName": "enter_plan_mode"]
        )
    }
}
