import Foundation

// MARK: - Skill Executor

/// 技能执行器 — 以 fork 子 Agent 的方式真正执行 skill workflow
///
/// 旧实现：SkillRegistry 只返回 workflow 文本给 LLM，AI 按步骤执行（prompt 注入占位）。
/// T05 改造：将 skill 的 workflow 作为任务描述交给子 Agent，由子 Agent 在隔离上下文中
/// 自主调用工具完成工作流。这样：
/// - 文件系统/权限与会话隔离（复用 SubAgentContext）
/// - 多个 skill 可并行执行
/// - skill 不再依赖主 Agent 的 prompt 上下文长度
///
/// 参考 Claude Code skill 执行模型：skills 作为独立 workflow，在子 agent 中执行。
struct SkillExecutor: Sendable {

    // MARK: - Execute

    /// 执行指定技能
    /// - Parameters:
    ///   - skill: 已解析的技能模型
    ///   - context: 父 Agent 的工具执行上下文（用于创建子 Agent）
    /// - Returns: ToolResult（子 Agent 执行结果摘要）
    func execute(skill: Skill, context: ToolExecutionContext) async -> ToolResult {
        guard let teamCoordinator = context.teamCoordinator else {
            return ToolResult.error(message: "技能执行需要 TeamCoordinator，但当前上下文未注入")
        }

        guard context.toolRegistry != nil else {
            return ToolResult.error(message: "技能执行需要 ToolRegistry，但当前上下文未注入")
        }

        // 构建子 Agent 任务描述 — 把 skill workflow 作为任务目标
        let taskDescription = """
        ## 技能执行: \(skill.name)

        \(skill.description)

        ### 工作流

        \(skill.workflow)

        ### 执行说明

        请严格按照上述工作流步骤逐一执行。每步完成后等待结果，根据结果决定下一步操作。
        如果工作流包含 git 操作，请使用 execute_command 工具；git 命令会被自动转发到 GitService。
        如果工作流需要文件读写，请使用 write_file / edit_file / read_file 等工具。
        最终返回执行结果摘要（成功完成了哪些步骤、失败原因、关键输出）。
        """

        // 使用 AgentTool 在独立上下文中执行 skill workflow
        let agentTool = AgentTool()
        let result = await agentTool.execute(
            input: [
                "description": taskDescription,
                "subagent_type": "coder",
                "name": "skill-\(skill.name)"
            ],
            context: context
        )

        // 包装结果：让主 Agent 知道这是 skill 执行结果
        if result.isError {
            return ToolResult.error(
                message: "技能「\(skill.name)」执行失败: \(result.output)",
                metadata: ["skillName": skill.name, "source": "\(skill.source)"]
            )
        }

        let wrappedOutput = """
        ✅ 技能「\(skill.name)」执行完成

        \(result.output)
        """

        return ToolResult.success(
            output: wrappedOutput,
            metadata: ["skillName": skill.name, "source": "\(skill.source)"]
        )
    }
}
