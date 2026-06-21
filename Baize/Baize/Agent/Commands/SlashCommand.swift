import Foundation

// MARK: - Command Result

/// 命令执行结果 — SlashCommand.execute() 的返回值
struct CommandResult: Sendable {
    /// 是否执行成功
    let success: Bool

    /// 输出文本（显示给用户或注入对话）
    let output: String

    /// 执行动作 — 指示调用方如何处理结果
    let action: CommandAction

    init(success: Bool, output: String, action: CommandAction = .showOutput) {
        self.success = success
        self.output = output
        self.action = action
    }
}

/// 命令执行动作 — 指示调用方如何处理命令结果
enum CommandAction: Sendable {
    /// 显示输出文本（默认）
    case showOutput
    /// 将 output 作为用户消息注入对话（如 /commit → 注入"请提交当前改动"）
    case injectAsUserMessage
    /// 显示帮助信息
    case showHelp
    /// 清空当前会话
    case clearSession
    /// 触发上下文压缩
    case compactContext
}

// MARK: - Slash Command Protocol

/// Slash 命令协议 — 所有 / 前缀命令实现此协议
/// 用户在输入框输入 /xxx 时触发，由 CommandRegistry 解析并执行
protocol SlashCommand: Sendable {
    /// 命令名称（不含 / 前缀，如 "commit"）
    var name: String { get }

    /// 命令描述
    var description: String { get }

    /// 用法说明（如 "/commit [message]"）
    var usage: String { get }

    /// 执行命令
    /// - Parameters:
    ///   - args: 命令参数（已按空格分割）
    ///   - context: 工具执行上下文
    /// - Returns: 命令执行结果
    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult
}

// MARK: - Built-in Commands

/// /commit — 调 AI 执行 git commit
struct CommitCommand: SlashCommand {
    let name = "commit"
    let description = "提交当前代码改动并生成提交消息"
    let usage = "/commit [可选：提交消息]"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        let message = args.joined(separator: " ")
        let prompt = message.isEmpty
            ? "请提交当前所有代码改动，执行 git add -A 和 git commit。根据改动内容自动生成合适的提交消息。"
            : "请提交当前所有代码改动，执行 git add -A 和 git commit -m \"\(message)\"。"
        return CommandResult(success: true, output: prompt, action: .injectAsUserMessage)
    }
}

/// /push — 调 AI 执行 git push
struct PushCommand: SlashCommand {
    let name = "push"
    let description = "推送代码到远程仓库"
    let usage = "/push"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        return CommandResult(
            success: true,
            output: "请执行 git push 将本地提交推送到远程仓库。如果需要先提交改动，请先执行 git add -A 和 git commit。",
            action: .injectAsUserMessage
        )
    }
}

/// /commit-push — 组合 commit + push
struct CommitPushCommand: SlashCommand {
    let name = "commit-push"
    let description = "提交并推送代码改动（组合操作）"
    let usage = "/commit-push [可选：提交消息]"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        let message = args.joined(separator: " ")
        let prompt = message.isEmpty
            ? "请提交并推送当前所有代码改动：1. git add -A  2. git commit（自动生成消息）  3. git push"
            : "请提交并推送当前所有代码改动：1. git add -A  2. git commit -m \"\(message)\"  3. git push"
        return CommandResult(success: true, output: prompt, action: .injectAsUserMessage)
    }
}

/// /review — 代码审查
struct ReviewCommand: SlashCommand {
    let name = "review"
    let description = "审查当前代码改动，输出问题/建议/风险"
    let usage = "/review"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        return CommandResult(
            success: true,
            output: "请审查当前代码改动（git diff），输出：1. 潜在问题  2. 改进建议  3. 风险评估。如果改动较多，分模块逐一审查。",
            action: .injectAsUserMessage
        )
    }
}

/// /compact — 触发上下文压缩
struct CompactCommand: SlashCommand {
    let name = "compact"
    let description = "手动触发上下文压缩"
    let usage = "/compact"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        return CommandResult(
            success: true,
            output: "上下文压缩已触发",
            action: .compactContext
        )
    }
}

/// /clear — 清空当前会话
struct ClearCommand: SlashCommand {
    let name = "clear"
    let description = "清空当前对话会话"
    let usage = "/clear"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        return CommandResult(
            success: true,
            output: "会话已清空",
            action: .clearSession
        )
    }
}

/// /agents — 列出可用 sub-agent
struct AgentsCommand: SlashCommand {
    let name = "agents"
    let description = "列出可用的子 agent"
    let usage = "/agents"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        // R1 阶段返回"暂无"，R2（T04 Sub-agent）后有效
        return CommandResult(
            success: true,
            output: "当前暂无可用子 agent。Sub-agent 团队功能将在后续版本中推出。",
            action: .showOutput
        )
    }
}

/// /skills — 列出已安装技能
struct SkillsCommand: SlashCommand {
    let name = "skills"
    let description = "列出已安装的技能"
    let usage = "/skills"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        guard let registry = context.skillRegistry else {
            return CommandResult(
                success: false,
                output: "技能注册表未初始化",
                action: .showOutput
            )
        }

        let skills = await registry.listSkills()
        if skills.isEmpty {
            return CommandResult(
                success: true,
                output: "暂无已安装技能",
                action: .showOutput
            )
        }

        let output = skills.map { skill in
            "- **\(skill.name)**: \(skill.description) [触发: \(skill.triggers.joined(separator: ", "))]"
        }.joined(separator: "\n")

        return CommandResult(success: true, output: output, action: .showOutput)
    }
}

/// /memory — 查看记忆
struct MemoryCommand: SlashCommand {
    let name = "memory"
    let description = "查看已存储的记忆"
    let usage = "/memory [user|project|team]"

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        guard let store = context.memoryStore else {
            return CommandResult(
                success: false,
                output: "记忆存储未初始化",
                action: .showOutput
            )
        }

        // 解析 scope 参数
        let scope: MemoryScope
        if let scopeArg = args.first, let s = MemoryScope(rawValue: scopeArg) {
            scope = s
        } else {
            scope = .user
        }

        let memories = await store.getMemories(scope: scope)
        if memories.isEmpty {
            return CommandResult(
                success: true,
                output: "暂无 \(scope.rawValue) 级记忆",
                action: .showOutput
            )
        }

        let output = memories.enumerated().map { index, memory in
            "[\(index + 1)] [\(memory.type.rawValue)] \(memory.content)\n    关键词: \(memory.keywords.joined(separator: ", "))"
        }.joined(separator: "\n\n")

        return CommandResult(success: true, output: output, action: .showOutput)
    }
}

/// /help — 显示帮助
struct HelpCommand: SlashCommand {
    let name = "help"
    let description = "显示可用命令列表"
    let usage = "/help"

    let allCommands: [(name: String, desc: String, usage: String)]

    init(allCommands: [(name: String, desc: String, usage: String)] = []) {
        self.allCommands = allCommands
    }

    func execute(args: [String], context: ToolExecutionContext) async -> CommandResult {
        let helpText = allCommands.map { cmd in
            "  \(cmd.usage) — \(cmd.desc)"
        }.joined(separator: "\n")

        let output = """
        可用命令：

        \(helpText)

        提示：直接输入问题与 AI 对话，或使用 / 前缀触发命令。
        """

        return CommandResult(success: true, output: output, action: .showHelp)
    }
}
