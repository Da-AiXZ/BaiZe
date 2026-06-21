import Foundation

/// ExitPlanMode 工具 — 退出计划模式（提交计划等待审批）
///
/// AI 使用此工具提交计划文本，退出计划模式。
/// 提交后挂起等待用户审批（approve/reject），审批结果通过 PlanModeState 的 continuation 恢复。
/// 用户批准后 AI 可以开始执行写操作；用户拒绝则 AI 需要修改计划或放弃。
struct ExitPlanModeTool: Tool {
    let name = "exit_plan_mode"
    let description = "退出计划模式，提交计划等待用户审批。用户批准后才能执行写操作。如果用户拒绝，需要根据反馈修改计划。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .planning

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["plan"],
        properties: [
            "plan": ["type": "string", "description": "计划文本 — 详细描述将执行的步骤"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let planModeState = context.planModeState else {
            return ToolResult.error(message: "PlanMode 状态机未初始化")
        }

        guard let plan = input["plan"] as? String, !plan.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: plan（计划文本不能为空）")
        }

        // 提交计划，挂起等待审批
        let approved = await planModeState.exit(plan: plan)

        if approved {
            return ToolResult.success(
                output: "计划已获用户批准。现在可以执行写操作了。请按照计划逐步执行。",
                metadata: ["toolName": "exit_plan_mode", "approved": "true"]
            )
        } else {
            return ToolResult.success(
                output: "计划被用户拒绝。请根据用户反馈修改计划或调整方案。",
                metadata: ["toolName": "exit_plan_mode", "approved": "false"]
            )
        }
    }
}
