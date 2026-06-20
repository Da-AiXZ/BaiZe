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

        // ios_system 将 70+ Unix 命令编译为进程内函数，无需 fork()
        // ios_system 默认不限制路径，安全由 PermissionEngine 负责

        // 诊断：检查 ios_system 命令字典是否加载成功
        let cmdList = commandsAsString() ?? "(empty)"
        let lsAvailable = ios_executable("ls")
        let echoAvailable = ios_executable("echo")
        runtimeLogger.info("ios_system initialized: \(cmdList.split(separator: " ").count) commands available, ls executable=\(lsAvailable), echo executable=\(echoAvailable)")
        if lsAvailable == 0 {
            runtimeLogger.error("ios_system: 'ls' not found! commandDictionary.plist may be missing from App Bundle resources")
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

    // MARK: - Shell Command Execution (ios_system)

    /// 执行 Shell 命令 — 使用 ios_system 库的 ios_popen
    /// ios_system 不需要 fork()，每个命令编译为独立函数直接在进程内调用
    /// 支持 ls/cat/grep/find/rm/mv/cp/tar/curl 等 70+ Unix 命令
    /// 如果 ios_popen 返回 nil（命令不可用），返回清晰的错误信息
    /// - Parameters:
    ///   - command: 命令字符串（如 "ls -la /var/mobile/Documents/Baize/"）
    ///   - workingDir: 工作目录（可选）
    /// - Returns: ExecutionResult
    func executeCommand(command: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute command: \(command)")

        let workingDirectory = workingDir ?? BaizePath.projectRoot

        // Bug 2 fix: echo 等简单命令在 ios_system 中可能不被 ios_popen 支持
        // 作为内置命令直接处理，确保基本命令始终有输出
        if let builtinResult = handleBuiltinCommand(command: command) {
            runtimeLogger.info("Builtin command handled: \(command)")
            return builtinResult
        }

        // 构建完整命令：仅当工作目录存在且可访问时才 cd
        let fullCommand: String
        if !workingDirectory.isEmpty && fileManager.fileExists(atPath: workingDirectory) {
            fullCommand = "cd '\(workingDirectory)' && \(command) 2>&1"
        } else {
            runtimeLogger.warning("Working directory not accessible: \(workingDirectory), running in default dir")
            fullCommand = "\(command) 2>&1"
        }

        // Bug 2 fix: 检查命令是否在 ios_system 中可用
        let cmdName = command.split(separator: " ").first.map(String.init) ?? command
        let cmdAvailable = ios_executable(cmdName)
        if cmdAvailable == 0 {
            runtimeLogger.warning("Command '\(cmdName)' may not be available in ios_system (ios_executable=0), will attempt ios_popen anyway")
        }

        // Bug 1 fix: 添加超时机制，防止 ios_popen 阻塞导致 Agent 卡住
        // ios_popen 是阻塞调用，如果命令等待输入（如 cat 无参数），会永久阻塞
        let timeoutSeconds = BaizeRuntime.commandTimeout

        return await withCheckedContinuation { continuation in
            // 使用锁保护 resumed 标志，防止超时和正常完成双重 resume
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

            DispatchQueue.global(qos: .userInitiated).async {
                let fp = ios_popen(fullCommand, "r")

                guard let filePtr = fp else {
                    runtimeLogger.error("ios_popen returned nil for: \(fullCommand)")
                    runtimeLogger.error("This usually means ios_system command dictionary not loaded, or command not supported")
                    resumeOnce(ExecutionResult(
                        stdout: "",
                        stderr: "命令不可用: ios_system 不支持 '\(command)'。可能原因: ios_system 未正确初始化，或该命令不在内置命令列表中。支持的命令: ls, cat, grep, find, rm, mv, cp, tar, curl 等 70+ Unix 命令。",
                        exitCode: -1,
                        isError: true
                    ))
                    return
                }

                // 通过 fgets 循环读取 stdout（已含 stderr 重定向）
                var buffer = [CChar](repeating: 0, count: 4096)
                var output = ""
                while fgets(&buffer, Int32(buffer.count), filePtr) != nil {
                    output += String(cString: buffer)
                }

                fclose(filePtr)

                // Bug 2 fix: 诊断日志 — 记录输出详情
                runtimeLogger.info("ios_popen completed: output \(output.utf8.count) bytes, first 200 chars: '\(output.prefix(200))'")

                // 如果输出为空但命令应该有输出，可能是 ios_system 不支持该命令
                if output.isEmpty && cmdAvailable == 0 {
                    runtimeLogger.warning("Command '\(cmdName)' produced no output and is not in ios_system command list. It may not be supported.")
                    resumeOnce(ExecutionResult(
                        stdout: "",
                        stderr: "命令 '\(command)' 没有产生输出。可能 ios_system 不支持此命令。可用命令包括: ls, cat, grep, find, git, curl 等 70+ Unix 命令。",
                        exitCode: 127,
                        isError: true
                    ))
                    return
                }

                resumeOnce(ExecutionResult(
                    stdout: output,
                    stderr: "",
                    exitCode: 0,
                    isError: false
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
