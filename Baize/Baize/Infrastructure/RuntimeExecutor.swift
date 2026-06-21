import Foundation
import ios_system

/// 代码执行引擎 — 策略模式重构
///
/// 对外接口不变（executeNode/executePython/executeCommand），内部通过策略委托：
/// - executeCommand → ios_system（进程内命令执行，不变）
/// - executeNode → NodeMobileStrategy → NodeRuntimeEngine → HTTP → Node.js（进程内）
/// - executePython → PythonEmbeddingStrategy → PythonRuntimeEngine → HTTP → Python（进程内，CPython 3.13 嵌入模式）
///
/// @unchecked Sendable：内部状态通过 Actor 隔离保证线程安全
class RuntimeExecutor: @unchecked Sendable {

    // MARK: - Execution Result

    /// 进程执行结果
    struct ExecutionResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let isError: Bool

        /// 格式化输出（stdout + stderr 合并）
        var formattedOutput: String {
            var output = stdout
            if !stderr.isEmpty {
                output += "\n[stderr]\n" + stderr
            }
            return output
        }
    }

    // MARK: - Properties

    /// Node.js 执行策略
    private let nodeStrategy: RuntimeStrategy

    /// Python 执行策略
    private let pythonStrategy: RuntimeStrategy

    /// FileManager 实例
    private let fileManager = FileManager.default

    /// Serial queue for ios_popen execution — prevents ios_setDirectoryURL() races.
    /// ios_setDirectoryURL() is process-wide (not thread-local), so concurrent executions
    /// would interfere with each other's working directory.
    private static let executeQueue = DispatchQueue(label: "com.baize.runtime.execute", qos: .userInitiated)

    // MARK: - Initialization

    /// 主初始化器 — 接受策略注入
    /// - Parameters:
    ///   - nodeStrategy: Node.js 执行策略（NodeMobileStrategy 或 NodeUnavailableStrategy）
    ///   - pythonStrategy: Python 执行策略（PythonEmbeddingStrategy 或 PythonUnavailableStrategy）
    init(
        nodeStrategy: RuntimeStrategy,
        pythonStrategy: RuntimeStrategy
    ) {
        self.nodeStrategy = nodeStrategy
        self.pythonStrategy = pythonStrategy

        // ── 方案 A：补全 ios_system 初始化序列 ──
        // initializeEnvironment() 设置 $HOME=~/Documents/, $PATH, $PYTHONHOME 等关键环境变量
        // 必须在任何 ios_system 命令执行前调用，否则命令可能因缺少环境变量而失败
        // 参考：ios_system/ios_system.h — extern void initializeEnvironment(void);
        initializeEnvironment()
        runtimeLogger.info("ios_system: initializeEnvironment() called — PATH/HOME/PYTHONHOME set")

        // 设置 miniRoot — 限制 ios_system 的可访问根目录
        // ios_setMiniRoot 接受 NSString*（Swift 导入为 String），传入路径字符串
        // 参考：ios_system.h — extern int ios_setMiniRoot(NSString*);
        let miniRootResult = ios_setMiniRoot(BaizePath.projectRoot)
        runtimeLogger.info("ios_system: miniRoot set to \(BaizePath.projectRoot) (result=\(miniRootResult))")

        // ios_system 将 70+ Unix 命令编译为进程内函数，无需 fork()
        // ios_system 默认不限制路径，安全由 PermissionEngine 负责

        // 诊断：检查 ios_system 命令字典是否加载成功（initializeEnvironment 后重新检查）
        let cmdList = commandsAsString() ?? "(empty)"
        let lsAvailable = ios_executable("ls")
        let echoAvailable = ios_executable("echo")
        runtimeLogger.info("ios_system initialized: \(cmdList.split(separator: " ").count) commands available, ls executable=\(lsAvailable), echo executable=\(echoAvailable)")
        if lsAvailable == 0 {
            runtimeLogger.error("ios_system: 'ls' not found after initializeEnvironment! commandDictionary.plist may be missing from App Bundle resources. NativeCommands fallback will handle ls.")
        }
        if echoAvailable == 0 {
            runtimeLogger.info("ios_system: 'echo' not found in command list — builtin handler will be used instead")
        }
    }

    /// 兼容旧调用的便捷初始化器 — 无 NodeRuntimeEngine 时使用降级策略
    /// 用于测试或未注入引擎时的 fallback
    convenience init() {
        self.init(
            nodeStrategy: NodeUnavailableStrategy(),
            pythonStrategy: PythonUnavailableStrategy()
        )
    }

    // MARK: - T03: Project Root Update

    /// T03: 更新 ios_setMiniRoot — 切换项目时重新设置进程级根目录
    /// ios_setMiniRoot 是进程级操作，限制 ios_system 的可访问根目录
    /// 必须在串行队列上执行以避免竞态
    /// - Parameter path: 新的项目根目录绝对路径
    func updateProjectRoot(_ path: String) {
        Self.executeQueue.sync {
            let result = ios_setMiniRoot(path)
            runtimeLogger.info("ios_system: miniRoot updated to \(path) (result=\(result))")
        }
    }

    // MARK: - Shell Command Execution (ios_system)

    /// 执行 Shell 命令 — 使用 ios_system 库的 ios_popen
    ///
    /// **根因修复**：ios_popen 不是真正的 shell，它调用 ios_system() 解析命令字符串。
    /// 旧代码构建 `cd 'path' && command 2>&1` 传给 ios_popen，但：
    /// 1. ios_system 的 cd_main 依赖 currentSession，若为 NULL 则返回 1
    /// 2. && 操作符在前命令失败时跳过后命令 → ls/cat/find 永不执行
    /// 3. ios_popen 在 ios_system 返回非零时返回 NULL → 无输出
    /// 4. 2>&1 语法可能不被 parser 识别，被当作命令参数 → 命令失败
    ///
    /// **修复方案**（A+B 双保险）：
    /// - 方案 A：init() 调用 initializeEnvironment() + ios_setMiniRoot() 补全 ios_system 初始化
    /// - 方案 A：用 ios_setDirectoryURL 替代 FileManager.changeCurrentDirectoryPath（chdir）
    ///           ios_setDirectoryURL 同时更新 POSIX CWD 和 ios_system 会话状态
    /// - 方案 B：高频命令（ls/cat/pwd/wc/stat/touch/mkdir/rm/cp/mv/head/tail）由 NativeCommands
    ///           Swift 原生实现，不依赖 ios_system，双保险 fallback
    /// - 移除 `2>&1` 后缀，只传裸命令给 ios_popen
    /// - 使用串行队列防止 ios_setDirectoryURL() 竞态（进程级，非线程级）
    /// - 移除激进的空输出检测（touch/mkdir 等命令合法地无输出）
    /// - 对 find/grep/du 等递归命令增加超时至 60 秒
    ///
    /// - Parameters:
    ///   - command: 命令字符串（如 "ls -la", "find . -name '*.swift'"）
    ///   - workingDir: 工作目录（可选，默认 BaizePath.projectRoot）
    /// - Returns: ExecutionResult
    func executeCommand(command: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute command: '\(command)' workingDir: \(workingDir ?? "nil")")

        let workingDirectory = workingDir ?? BaizePath.projectRoot

        // echo/printf/true/false/whoami 等 builtin 命令直接处理
        if let builtinResult = handleBuiltinCommand(command: command) {
            runtimeLogger.info("Builtin command handled: \(command)")
            return builtinResult
        }

        // 方案 B：高频命令 Swift 原生 fallback
        // ls/cat/pwd/wc/stat/touch/mkdir/rm/cp/mv/head/tail 由 NativeCommands 直接处理
        // 不依赖 ios_system，确保即使 ios_system 未正确初始化也能正常工作
        // 返回 nil 表示不是原生命令（含 shell 操作符或不在支持列表中），继续走 ios_popen
        if let nativeResult = NativeCommands.execute(command: command, workingDir: workingDirectory) {
            runtimeLogger.info("Native command handled: \(command)")
            return nativeResult
        }

        // 提取命令名（用于 git 拦截和 ios_executable 检查）
        let cmdName = command.split(separator: " ").first.map(String.init) ?? command

        // git 命令不在 ios_system 支持列表中（commandDictionary.plist 无 git key）。
        // 项目有完整的 GitService (libgit2) 实现，应使用 GitService 而非 shell git。
        // 拦截 git 命令，避免 ios_popen 60 秒超时。
        if cmdName == "git" {
            runtimeLogger.info("Git command intercepted — use GitService instead of ios_popen")

            // git clone 专项拦截 — 引导用户通过 Dashboard 新建项目流程操作
            let lowerCmd = command.lowercased()
            if lowerCmd.contains("clone") {
                return ExecutionResult(
                    stdout: "",
                    stderr: "⚠️ Git clone 请通过 Dashboard → 新建项目 → 从 Git clone 创建 进行操作。",
                    exitCode: 1,
                    isError: true
                )
            }

            return ExecutionResult(
                stdout: "",
                stderr: "⚠️ 'git' 命令在 iOS 沙箱中不可用。\n白泽使用 Git Tab (libgit2) 提供完整 Git 操作支持。\n\n可用操作：status, log, diff, stage, commit, push, pull, fetch, merge, rebase, stash, reset, tag, branch, checkout\n\n请切换到 Git Tab 进行操作。",
                exitCode: 1,
                isError: true
            )
        }

        // 检查命令是否在 ios_system 字典中可用
        let cmdAvailable = ios_executable(cmdName)
        runtimeLogger.info("ios_executable('\(cmdName)') = \(cmdAvailable)")
        if cmdAvailable == 0 {
            runtimeLogger.warning("Command '\(cmdName)' not in ios_system dictionary (ios_executable=0)")
        }

        // 动态超时：递归/搜索类命令给 60 秒，其他 30 秒
        let longRunningCommands: Set<String> = ["find", "grep", "du", "tar", "diff", "curl"]
        let timeoutSeconds: TimeInterval = longRunningCommands.contains(cmdName) ? 60.0 : BaizeRuntime.commandTimeout

        return await withCheckedContinuation { continuation in
            // NSLock 保护 resumed 标志，防止超时和正常完成双重 resume
            let lock = NSLock()
            var hasResumed = false

            let resumeOnce: (ExecutionResult) -> Void = { result in
                lock.lock()
                let shouldResume = !hasResumed
                hasResumed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(returning: result)
                }
            }

            // 串行队列执行 — ios_setDirectoryURL 是进程级操作，必须串行化
            RuntimeExecutor.executeQueue.async {
                // ── Phase 1: 设置工作目录 (方案 A: ios_setDirectoryURL) ──
                // ios_setDirectoryURL 是 ios_system 提供的正确设置工作目录方式
                // 它同时更新 POSIX CWD (chdir) 和 ios_system 内部会话状态
                // 比 FileManager.changeCurrentDirectoryPath 更可靠 —
                // 后者只改 POSIX CWD，不影响 ios_system session 的 workingDirectory
                // Swift 导入签名: ios_setDirectoryURL(_ url: URL?) — 直接传 URL，不要 as NSURL
                let originalDir = FileManager.default.currentDirectoryPath
                var chdirSuccess = false

                if !workingDirectory.isEmpty && self.fileManager.fileExists(atPath: workingDirectory) {
                    let workURL = URL(fileURLWithPath: workingDirectory)
                    ios_setDirectoryURL(workURL)
                    chdirSuccess = true
                    runtimeLogger.info("ios_setDirectoryURL('\(workingDirectory)') called")
                } else {
                    runtimeLogger.warning("Working directory not accessible: \(workingDirectory), running in '\(originalDir)'")
                }

                // ── Phase 2: 执行裸命令 ──
                // 只传原始命令给 ios_popen，不加 cd 前缀和 2>&1 后缀
                // ios_popen 内部调用 ios_system() 解析命令字符串
                // 命令中的 shell 操作符（|, >, <, &&, ||, ;）由 ios_system parser 处理
                runtimeLogger.info("ios_popen raw command: '\(command)'")
                let fp = ios_popen(command, "r")

                // 立即恢复原始工作目录 (方案 A: ios_setDirectoryURL)
                // ios_popen 是同步调用 — 命令已执行完毕，输出已在管道缓冲区中
                ios_setDirectoryURL(URL(fileURLWithPath: originalDir))

                // ── Phase 3: 处理 NULL 返回值 ──
                // ios_popen 在 ios_system 返回非零时返回 NULL
                // 可能原因：命令不存在、命令执行失败、命令字符串解析失败
                guard let filePtr = fp else {
                    runtimeLogger.error("ios_popen returned nil for: '\(command)'")
                    runtimeLogger.error("  cmdAvailable=\(cmdAvailable), chdirSuccess=\(chdirSuccess), workingDir=\(workingDirectory)")

                    // 构建诊断信息
                    var diagMsg = "命令执行失败: '\(command)'"
                    if cmdAvailable == 0 {
                        diagMsg += "\n  原因: '\(cmdName)' 不在 ios_system 命令列表中"
                        diagMsg += "\n  可用命令: ls, cat, grep, find, rm, mv, cp, tar, curl, head, tail, wc, sort, sed, awk 等"

                        // ★ 命令名容错提示
                        // 处理用户输入 "find." / "ls-la" 等手误（命令名与参数间漏空格）
                        let knownCommands: Set<String> = [
                            "ls","cat","pwd","wc","stat","touch","mkdir","rm","cp","mv",
                            "head","tail","find","grep","sed","awk","sort","uniq","diff",
                            "tar","curl","echo","printf","tr","cut","du","df","chmod","chown","ln"
                        ]
                        for known in knownCommands {
                            if cmdName.hasPrefix(known) && cmdName.count > known.count {
                                let nextIdx = cmdName.index(cmdName.startIndex, offsetBy: known.count)
                                let nextChar = cmdName[nextIdx]
                                if !nextChar.isLetter {
                                    diagMsg += "\n  提示：'\(cmdName)' 不是有效命令，您是不是想输入 '\(known) ...'（注意空格）？"
                                    break
                                }
                            }
                        }
                    } else if !chdirSuccess {
                        diagMsg += "\n  原因: 无法切换到工作目录 '\(workingDirectory)'"
                    } else {
                        diagMsg += "\n  命令存在但执行返回非零退出码（可能权限不足或参数错误）"
                    }

                    resumeOnce(ExecutionResult(
                        stdout: "",
                        stderr: diagMsg,
                        exitCode: -1,
                        isError: true
                    ))
                    return
                }

                // ── Phase 4: 读取输出 ──
                var buffer = [CChar](repeating: 0, count: 4096)
                var output = ""
                var lineCount = 0
                while fgets(&buffer, Int32(buffer.count), filePtr) != nil {
                    output += String(cString: buffer)
                    lineCount += 1
                }
                // T01-2 fix 尝试: 用 pclose 替代 fclose 捕获退出码
                // 但实测 iOS Swift 中 pclose 被标记为不可用：
                //   'pclose' is unavailable in Swift: Use posix_spawn APIs or NSTask instead.
                //   (On iOS, process spawning is unavailable.)
                // ios_popen 是 ios_system 库的进程内实现（非标准 popen），
                // ios_system 未提供 ios_pclose API，iOS 又禁止 pclose → 无法获取退出码
                // 保留 fclose 关闭流，exitCode 保持 0（已知限制）
                // 高频命令（ls/cat/grep/find 等）已由 NativeCommands 正确返回 exitCode
                fclose(filePtr)
                let realExitCode: Int32 = 0

                runtimeLogger.info("ios_popen completed: \(lineCount) lines, \(output.utf8.count) bytes, exitCode: \(realExitCode), first 200: '\(output.prefix(200))'")

                // ── Phase 5: 返回结果 ──
                // 空输出是合法的 — touch/mkdir/true 等命令不产生输出
                // 注意：ios_popen 路径 exitCode 恒为 0（iOS 限制无法用 pclose 获取真实退出码）
                // 高频命令的 exitCode 由 NativeCommands 正确处理（ls/cat/grep/find 等）
                resumeOnce(ExecutionResult(
                    stdout: output,
                    stderr: "",
                    exitCode: realExitCode,
                    isError: realExitCode != 0
                ))
            }

            // 超时处理：超时后返回错误，ios_popen 在后台继续运行但不影响结果
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeOnce(ExecutionResult(
                    stdout: "",
                    stderr: "命令执行超时（\(Int(timeoutSeconds))秒）：\(command)",
                    exitCode: -1,
                    isError: true
                ))
            }
        }
    }

    // MARK: - Builtin Command Handling (Bug 2 fix)

    /// 处理 ios_system 可能不支持的简单命令（echo、printf、true、false 等）
    /// 这些命令是 shell 内置命令，ios_popen 可能无法正确捕获其输出
    /// 仅处理不含 shell 操作符（|, &&, ||, ;, >, <）的简单命令
    /// - Parameter command: 原始命令字符串
    /// - Returns: 如果是内置命令则返回执行结果，否则返回 nil（继续走 ios_popen 路径）
    private func handleBuiltinCommand(command: String) -> ExecutionResult? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // 含 shell 操作符的命令不走 builtin（需要 ios_system 解析）
        let shellOperators: Set<Character> = ["|", ">", "<"]
        if trimmed.contains("&&") || trimmed.contains("||") || trimmed.contains(";") {
            return nil
        }
        if trimmed.contains(where: { shellOperators.contains($0) }) {
            return nil
        }

        // echo 命令 — ios_system 可能不支持通过 ios_popen 执行
        if trimmed == "echo" {
            return ExecutionResult(stdout: "\n", stderr: "", exitCode: 0, isError: false)
        }
        if trimmed.hasPrefix("echo ") {
            return handleEchoBuiltin(command: trimmed)
        }

        // printf 命令 — 简化版，仅支持基本格式
        if trimmed == "printf" {
            return ExecutionResult(stdout: "", stderr: "", exitCode: 0, isError: false)
        }

        // true / false 命令
        if trimmed == "true" {
            return ExecutionResult(stdout: "", stderr: "", exitCode: 0, isError: false)
        }
        if trimmed == "false" {
            return ExecutionResult(stdout: "", stderr: "", exitCode: 1, isError: true)
        }

        // whoami 命令 — 返回 mobile（iOS 默认用户）
        if trimmed == "whoami" {
            return ExecutionResult(stdout: "mobile\n", stderr: "", exitCode: 0, isError: false)
        }

        return nil
    }

    /// 处理 echo 内置命令
    /// 支持 -n（不换行）和基本引号处理
    private func handleEchoBuiltin(command: String) -> ExecutionResult {
        // 提取 echo 后面的参数
        let argsStr = String(command.dropFirst(5)) // 去掉 "echo "

        var noNewline = false
        var interpretEscapes = false
        var remaining = argsStr

        // 解析 flags (-n, -e, -E, -ne, -en 等)
        while remaining.hasPrefix("-") && remaining.count > 1 {
            let flagPart = remaining.split(separator: " ", maxSplits: 1).first ?? Substring(remaining)
            let flags = String(flagPart)
            // 只处理已知 flag 组合
            let knownFlags = Set(["-n", "-e", "-E", "-ne", "-en", "-nE", "-En"])
            if !knownFlags.contains(flags) {
                break
            }
            if flags.contains("n") { noNewline = true }
            if flags.contains("e") { interpretEscapes = true }
            if flags.contains("E") { interpretEscapes = false }
            remaining = String(remaining.dropFirst(flags.count)).trimmingCharacters(in: .whitespaces)
        }

        var text = remaining

        // 处理引号：移除最外层引号
        if text.count >= 2 {
            if (text.hasPrefix("\"") && text.hasSuffix("\"")) {
                text = String(text.dropFirst().dropLast())
            } else if (text.hasPrefix("'") && text.hasSuffix("'")) {
                text = String(text.dropFirst().dropLast())
            }
        }

        // 处理转义序列（-e 标志）
        if interpretEscapes {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
                       .replacingOccurrences(of: "\\t", with: "\t")
                       .replacingOccurrences(of: "\\\\", with: "\\")
        }

        let output = noNewline ? text : text + "\n"

        return ExecutionResult(
            stdout: output,
            stderr: "",
            exitCode: 0,
            isError: false
        )
    }

    // MARK: - Node.js Script Execution (delegate to strategy)

    /// 执行 Node.js 脚本 — 委托给 nodeStrategy
    /// - Parameters:
    ///   - script: JavaScript 代码内容
    ///   - workingDir: 工作目录
    /// - Returns: ExecutionResult
    func executeNode(script: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute Node.js script (\(script.utf8.count) bytes)")
        return await nodeStrategy.execute(script: script, workingDir: workingDir)
    }

    // MARK: - Python Script Execution (delegate to strategy)

    /// 执行 Python 脚本 — 委托给 pythonStrategy
    /// - Parameters:
    ///   - script: Python 代码内容
    ///   - workingDir: 工作目录
    /// - Returns: ExecutionResult
    func executePython(script: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute Python script (\(script.utf8.count) bytes)")
        return await pythonStrategy.execute(script: script, workingDir: workingDir)
    }
}
