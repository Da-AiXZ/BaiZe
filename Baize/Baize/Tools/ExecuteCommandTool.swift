import Foundation

/// 执行 Shell 命令工具 — 通过 ios_system / posix_spawn 执行命令
/// 破坏性工具，权限引擎需要 ask（用户需确认执行的命令）
/// Phase 1: 使用 RuntimeExecutor 的 executeCommand 方法
struct ExecuteCommandTool: Tool {

    let name = "execute_command"
    let description = "执行 Shell 命令。支持 ios_system 内置命令（ls, cat, grep, find, git 等 70+ 命令）和 posix_spawn 执行。命令执行后返回 stdout 和 stderr 输出。注意：iOS 上无交互式 Shell，仅支持命令-输出模式。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["command"],
        properties: [
            "command": SchemaBuilder.stringProperty(description: "要执行的 Shell 命令（如 'ls -la', 'git status', 'npm test'）"),
            "working_dir": SchemaBuilder.pathProperty(description: "命令执行的工作目录（默认为项目根目录）"),
        ]
    )

    private let runtimeExecutor: RuntimeExecutor

    init(runtimeExecutor: RuntimeExecutor) {
        self.runtimeExecutor = runtimeExecutor
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let command = input["command"] as? String else {
            return ToolResult.error(message: "缺少必填参数: command")
        }

        let workingDir = input["working_dir"] as? String ?? context.projectPath

        // 安全检查：拒绝危险命令模式
        for pattern in BaizePermission.alwaysDenyPatterns {
            if command.contains(pattern) {
                return ToolResult.error(message: "拒绝执行危险命令: 命令包含禁止模式 '\(pattern)'")
            }
        }

        toolLogger.info("execute_command: \(command) in \(workingDir)")

        let result = await runtimeExecutor.executeCommand(
            command: command,
            workingDir: workingDir
        )

        if result.isError {
            return ToolResult.error(
                message: "命令执行失败 (exit code \(result.exitCode))\n\(result.formattedOutput)",
                metadata: ["command": command, "exitCode": "\(result.exitCode)"]
            )
        } else {
            return ToolResult.success(
                output: result.formattedOutput,
                metadata: [
                    "command": command,
                    "exitCode": "\(result.exitCode)",
                    "stdoutBytes": "\(result.stdout.utf8.count)",
                ]
            )
        }
    }
}