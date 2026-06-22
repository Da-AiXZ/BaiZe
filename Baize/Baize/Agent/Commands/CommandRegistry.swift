import Foundation

/// 命令注册表 — 管理 Slash 命令的注册、解析和执行
///
/// 用户在输入框输入 /xxx 时，CommandRegistry.parse() 解析命令名和参数，
/// 然后调 execute() 执行对应命令。
/// 启动时自动注册 10 个内置命令（commit/push/commit-push/review/compact/clear/agents/skills/memory/help）
actor CommandRegistry {

    // MARK: - Properties

    /// 已注册命令字典 — name → SlashCommand
    private var commands: [String: any SlashCommand] = [:]

    // MARK: - Initialization

    init() {
        registerBuiltinCommands()
        commandLogger.info("CommandRegistry initialized with \(self.commands.count) built-in commands")
    }

    // MARK: - Registration

    /// 注册命令
    /// - Parameter command: 要注册的命令实例
    func register(_ command: any SlashCommand) {
        commands[command.name] = command
        commandLogger.info("Command registered: /\(command.name)")
    }

    /// 注销命令
    /// - Parameter name: 命令名称
    func unregister(name: String) {
        commands.removeValue(forKey: name)
        commandLogger.info("Command unregistered: /\(name)")
    }

    // MARK: - Parsing

    /// 解析用户输入，提取命令名和参数
    /// - Parameter input: 用户输入文本（如 "/commit fix bug"）
    /// - Returns: (命令实例, 参数数组)，如果不是命令返回 nil
    func parse(input: String) -> (any SlashCommand, [String])? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 必须以 / 开头
        guard trimmed.hasPrefix("/") else {
            return nil
        }

        // 去除 / 前缀
        let withoutSlash = String(trimmed.dropFirst())

        // 按空格分割
        let parts = withoutSlash.split(separator: " ", omittingEmptySubsequences: true)
        guard let firstPart = parts.first else {
            return nil
        }

        let commandName = String(firstPart)
        let args = parts.dropFirst().map(String.init)

        // 查找已注册命令
        guard let command = commands[commandName] else {
            return nil
        }

        return (command, args)
    }

    // MARK: - Execution

    /// 执行命令
    /// - Parameters:
    ///   - command: 命令实例
    ///   - args: 参数数组
    ///   - context: 工具执行上下文
    /// - Returns: 命令执行结果
    func execute(
        command: any SlashCommand,
        args: [String],
        context: ToolExecutionContext
    ) async -> CommandResult {
        commandLogger.info("Executing command: /\(command.name) with args: \(args)")
        return await command.execute(args: args, context: context)
    }

    // MARK: - Querying

    /// 获取所有已注册命令
    /// - Returns: 命令实例列表
    func listCommands() -> [any SlashCommand] {
        Array(commands.values).sorted { $0.name < $1.name }
    }

    /// 检查命令是否已注册
    /// - Parameter name: 命令名称
    /// - Returns: 是否已注册
    func hasCommand(name: String) -> Bool {
        commands[name] != nil
    }

    /// P1-#20 fix: 按前缀搜索命令（用于 slash 命令补全）
    /// - Parameter prefix: 命令名前缀（不含 /）
    /// - Returns: 匹配的命令列表（最多 5 个）
    func searchCommands(prefix: String) -> [any SlashCommand] {
        if prefix.isEmpty {
            return Array(commands.values).sorted { $0.name < $1.name }.prefix(5).map { $0 }
        }
        let lowercased = prefix.lowercased()
        let matched = commands.values
            .filter { $0.name.lowercased().hasPrefix(lowercased) }
            .sorted { $0.name < $1.name }
        return Array(matched.prefix(5))
    }

    // MARK: - Built-in Commands Registration

    /// 注册 10 个内置命令
    private func registerBuiltinCommands() {
        let commitCmd = CommitCommand()
        let pushCmd = PushCommand()
        let commitPushCmd = CommitPushCommand()
        let reviewCmd = ReviewCommand()
        let compactCmd = CompactCommand()
        let clearCmd = ClearCommand()
        let agentsCmd = AgentsCommand()
        let skillsCmd = SkillsCommand()
        let memoryCmd = MemoryCommand()

        // 收集所有命令信息供 /help 使用
        let allCommandInfo: [(name: String, desc: String, usage: String)] = [
            (commitCmd.name, commitCmd.description, commitCmd.usage),
            (pushCmd.name, pushCmd.description, pushCmd.usage),
            (commitPushCmd.name, commitPushCmd.description, commitPushCmd.usage),
            (reviewCmd.name, reviewCmd.description, reviewCmd.usage),
            (compactCmd.name, compactCmd.description, compactCmd.usage),
            (clearCmd.name, clearCmd.description, clearCmd.usage),
            (agentsCmd.name, agentsCmd.description, agentsCmd.usage),
            (skillsCmd.name, skillsCmd.description, skillsCmd.usage),
            (memoryCmd.name, memoryCmd.description, memoryCmd.usage),
        ]

        let helpCmd = HelpCommand(allCommands: allCommandInfo + [("help", "显示可用命令列表", "/help")])

        commands[commitCmd.name] = commitCmd
        commands[pushCmd.name] = pushCmd
        commands[commitPushCmd.name] = commitPushCmd
        commands[reviewCmd.name] = reviewCmd
        commands[compactCmd.name] = compactCmd
        commands[clearCmd.name] = clearCmd
        commands[agentsCmd.name] = agentsCmd
        commands[skillsCmd.name] = skillsCmd
        commands[memoryCmd.name] = memoryCmd
        commands[helpCmd.name] = helpCmd
    }
}
