import Foundation

/// 执行 Shell 命令工具 — 通过 ios_system / posix_spawn 执行命令
/// 破坏性工具，权限引擎需要 ask（用户需确认执行的命令）
/// Phase 1: 使用 RuntimeExecutor 的 executeCommand 方法
struct ExecuteCommandTool: Tool {

    let name = "execute_command"
    let description = "执行 Shell 命令。支持 ios_system 内置命令（ls, cat, grep, find, git 等 70+ 命令）和 posix_spawn 执行。命令执行后返回 stdout 和 stderr 输出。注意：iOS 上无交互式 Shell，仅支持命令-输出模式。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
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

        // P0-2 fix: 拦截 git 命令，转给 GitService（libgit2）
        // iOS 沙箱中无 git 二进制，ios_system 执行 git 会失败
        // 白泽内置 GitService（libgit2 封装），拦截 git 命令转给 GitService 执行
        if command.hasPrefix("git ") || command == "git" {
            return await executeGitCommand(command, context: context)
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

    // MARK: - P0-2: Git Command Interception

    /// 拦截 git 命令并转给 GitService（libgit2）执行
    /// 解析 git 子命令（status/add/commit/log/diff/push/pull/branch/init 等），
    /// 调用 GitService 对应方法，返回格式化结果
    private func executeGitCommand(_ command: String, context: ToolExecutionContext) async -> ToolResult {
        guard let gitService = context.gitService else {
            return ToolResult.error(
                message: "Git 服务未初始化。无法执行: \(command)\n请确保已打开一个项目（含 .git 仓库）。",
                metadata: ["command": command]
            )
        }

        // 解析 git 子命令和参数
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return ToolResult.error(message: "git 命令缺少子命令: \(command)")
        }

        let subcommandAndArgs = String(parts[1])
        let subcommandParts = subcommandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let subcommand = String(subcommandParts[0])
        let remainingArgs = subcommandParts.count > 1 ? String(subcommandParts[1]) : ""

        do {
            switch subcommand {
            // ── 只读操作 ──
            case "status":
                let status = try await gitService.status()
                let output = formatGitStatus(status)
                return ToolResult.success(output: output, metadata: ["command": command])

            case "log":
                let limit: Int
                if remainingArgs.contains("-n ") {
                    let nParts = remainingArgs.components(separatedBy: "-n ")
                    if nParts.count > 1, let n = Int(nParts[1].split(separator: " ").first ?? "") {
                        limit = n
                    } else {
                        limit = BaizeGit.defaultLogLimit
                    }
                } else {
                    limit = BaizeGit.defaultLogLimit
                }
                let commits = try await gitService.log(limit: limit)
                let output = formatGitLog(commits)
                return ToolResult.success(output: output, metadata: ["command": command])

            case "diff":
                let filePath = remainingArgs.isEmpty ? "" : String(remainingArgs.split(separator: " ").first ?? "")
                if filePath.isEmpty {
                    // 无文件路径 — 显示所有改动文件列表
                    let status = try await gitService.status()
                    var changedFiles: [String] = []
                    changedFiles.append(contentsOf: status.staged.map { "staged:   \($0.changeStatus.icon) \($0.path)" })
                    changedFiles.append(contentsOf: status.modified.map { "modified: \($0.changeStatus.icon) \($0.path)" })
                    let output = changedFiles.isEmpty
                        ? "(无差异)"
                        : "改动文件列表:\n\(changedFiles.joined(separator: "\n"))\n\n使用 'git diff <文件路径>' 查看具体差异"
                    return ToolResult.success(output: output, metadata: ["command": command])
                } else {
                    let diffResult = try await gitService.diff(filePath: filePath, diffType: .workingTreeVsIndex)
                    let output = diffResult.rawPatch
                    return ToolResult.success(output: output.isEmpty ? "(无差异)" : output, metadata: ["command": command])
                }

            case "branch":
                if remainingArgs == "" || remainingArgs == "-l" || remainingArgs == "--list" {
                    let branches = try await gitService.listBranches()
                    let output = branches.map { b in
                        "\(b.isCurrent ? "* " : "  ")\(b.name)"
                    }.joined(separator: "\n")
                    return ToolResult.success(output: output, metadata: ["command": command])
                } else {
                    return ToolResult.error(
                        message: "git branch 子命令 '\(remainingArgs)' 暂不支持。可用: git branch (列出分支)",
                        metadata: ["command": command]
                    )
                }

            // ── 写操作 ──
            case "add":
                if remainingArgs == "." || remainingArgs == "-A" || remainingArgs == "--all" {
                    try await gitService.stageAll()
                    return ToolResult.success(output: "已暂存所有改动", metadata: ["command": command])
                } else if !remainingArgs.isEmpty {
                    let filePath = String(remainingArgs.split(separator: " ").first ?? "")
                    try await gitService.stage(filePath: filePath)
                    return ToolResult.success(output: "已暂存: \(filePath)", metadata: ["command": command])
                } else {
                    return ToolResult.error(message: "git add 需要指定文件路径或 .", metadata: ["command": command])
                }

            case "commit":
                var message = ""
                if remainingArgs.contains("-m ") {
                    let mParts = remainingArgs.components(separatedBy: "-m ")
                    if mParts.count > 1 {
                        let msgPart = mParts[1].trimmingCharacters(in: .whitespaces)
                        if msgPart.hasPrefix("\"") {
                            // 引号包裹的消息 — 去掉首尾引号
                            var msg = String(msgPart.dropFirst())
                            if msg.hasSuffix("\"") {
                                msg = String(msg.dropLast())
                            }
                            message = msg
                        } else {
                            // 无引号 — 取第一个空格前的部分
                            message = String(msgPart.split(separator: " ").first ?? "")
                        }
                    }
                }
                if message.isEmpty {
                    return ToolResult.error(message: "git commit 需要 -m 参数指定提交消息", metadata: ["command": command])
                }
                try await gitService.commit(message: message)
                return ToolResult.success(output: "提交成功: \(message)", metadata: ["command": command])

            case "push":
                try await gitService.push()
                return ToolResult.success(output: "推送成功", metadata: ["command": command])

            case "pull":
                let mergeResult = try await gitService.pull()
                if mergeResult.success {
                    if mergeResult.isFastForward {
                        return ToolResult.success(output: "拉取成功 (fast-forward)", metadata: ["command": command])
                    } else {
                        return ToolResult.success(output: "拉取成功 (merge)", metadata: ["command": command])
                    }
                } else {
                    let conflictMsg = mergeResult.conflictFiles.isEmpty
                        ? "拉取失败"
                        : "合并冲突，冲突文件:\n\(mergeResult.conflictFiles.joined(separator: "\n"))"
                    return ToolResult.error(message: conflictMsg, metadata: ["command": command])
                }

            case "init":
                try await gitService.initRepository()
                return ToolResult.success(output: "Git 仓库已初始化", metadata: ["command": command])

            case "checkout":
                if !remainingArgs.isEmpty {
                    let branchName = String(remainingArgs.split(separator: " ").first ?? "")
                    try await gitService.checkoutBranch(branchName)
                    return ToolResult.success(output: "已切换到分支: \(branchName)", metadata: ["command": command])
                } else {
                    return ToolResult.error(message: "git checkout 需要指定分支名", metadata: ["command": command])
                }

            // ── 不支持的操作 ──
            case "stash", "rebase", "reset", "tag", "merge", "fetch", "clone", "remote", "config":
                return ToolResult.error(
                    message: "git \(subcommand) 暂不支持通过命令行执行。请使用 Git 面板的对应功能。",
                    metadata: ["command": command]
                )

            default:
                return ToolResult.error(
                    message: "不支持的 git 子命令: \(subcommand)。\n支持的命令: status, log, diff, add, commit, push, pull, init, branch, checkout",
                    metadata: ["command": command]
                )
            }
        } catch {
            return ToolResult.error(
                message: "git 命令执行失败: \(error.localizedDescription)",
                metadata: ["command": command]
            )
        }
    }

    // MARK: - Git Output Formatting

    /// 格式化 git status 输出
    private func formatGitStatus(_ status: GitStatus) -> String {
        var lines: [String] = []
        lines.append("位于分支: \(status.currentBranch)")

        if !status.staged.isEmpty {
            lines.append("")
            lines.append("要提交的变更（暂存区）:")
            for f in status.staged {
                lines.append("  \(f.changeStatus.icon) \(f.path)")
            }
        }

        if !status.modified.isEmpty {
            lines.append("")
            lines.append("尚未暂存以备提交的变更（工作区）:")
            for f in status.modified {
                lines.append("  \(f.changeStatus.icon) \(f.path)")
            }
        }

        if !status.untracked.isEmpty {
            lines.append("")
            lines.append("未跟踪的文件:")
            for f in status.untracked {
                lines.append("  ?? \(f.path)")
            }
        }

        if status.staged.isEmpty && status.modified.isEmpty && status.untracked.isEmpty {
            lines.append("")
            lines.append("无文件要提交，干净的工作区")
        }

        return lines.joined(separator: "\n")
    }

    /// 格式化 git log 输出
    private func formatGitLog(_ commits: [GitCommit]) -> String {
        if commits.isEmpty {
            return "（无提交历史）"
        }
        var lines: [String] = []
        for commit in commits {
            let dateStr = commit.date.formatted(.dateTime.year().month().day().hour().minute())
            lines.append("commit \(commit.oid)")
            lines.append("Author: \(commit.author) <\(commit.email)>")
            lines.append("Date:   \(dateStr)")
            lines.append("")
            // 缩进提交消息
            for msgLine in commit.message.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(msgLine)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}