import Foundation

/// Skill 工具 — 调用已安装的 Skill
///
/// AI 使用此工具按名称调用已安装的技能。
/// 技能的工作流文本返回给 AI，AI 按步骤执行。
/// 由于技能可能触发写操作，权限级别设为 .askUser。
struct SkillTool: Tool {
    let name = "skill"
    let description = "调用已安装的技能。技能包含预定义的工作流步骤。使用前确保技能已通过 SkillRegistry 加载。"
    let isReadOnly = false
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .askUser
    let category: ToolCategory = .skill

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["name"],
        properties: [
            "name": ["type": "string", "description": "技能名称（kebab-case，如 'commit-push', 'review', 'fix-bug'）"]
        ]
    )

    func isAvailable(context: ToolExecutionContext) -> Bool {
        context.skillRegistry != nil
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let skillName = input["name"] as? String, !skillName.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: name（技能名称）")
        }

        guard let skillRegistry = context.skillRegistry else {
            return ToolResult.error(message: "技能注册表未初始化")
        }

        // 检查技能是否存在
        let hasSkill = await skillRegistry.hasSkill(name: skillName)
        guard hasSkill else {
            // 列出可用技能供 AI 参考
            let skills = await skillRegistry.listSkills()
            let availableNames = skills.map { $0.name }.joined(separator: ", ")
            return ToolResult.error(
                message: "未找到技能: \(skillName)。可用技能: \(availableNames.isEmpty ? "（暂无已安装技能）" : availableNames)"
            )
        }

        // 执行技能 — 返回工作流文本给 AI
        // P1-#13 fix (round 2): 增强 skill 执行结果的指令清晰度
        // 之前 skill 返回的 workflow 文本不够明确，AI 不知道应该按步骤执行
        // 现在 skill 执行结果包含明确的执行指令，让 AI 知道这是一个需要逐步执行的工作流
        let result = await skillRegistry.executeSkill(name: skillName, context: context)
        
        // P1-#13 fix (round 2): 如果 skill 执行成功，追加更明确的执行指令
        if !result.isError {
            let enhancedOutput = """
            \(result.output)
            
            ---
            ⚡ 以上是技能「\(skillName)」的预定义工作流。请严格按照上述步骤逐一执行，每步使用对应的工具完成。不要跳过任何步骤。
            """
            return ToolResult.success(
                output: enhancedOutput,
                metadata: result.metadata
            )
        }
        
        return result
    }
}
