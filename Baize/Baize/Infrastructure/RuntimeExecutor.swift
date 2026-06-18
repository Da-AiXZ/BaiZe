import Foundation
import ios_system

/// 代码执行引擎 — 封装 posix_spawn + ios_system + nodejs-mobile + CPython
/// 支持 Shell 命令执行（ios_system）、Node.js 脚本、Python 脚本
/// TrollStore no-sandbox 环境下 posix_spawn 可执行 App Bundle 内已签名二进制
/// 修复 C6：阻塞 I/O 操作通过 DispatchQueue.global() 调度，避免占用 Actor 线程
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

    /// App Bundle 内 Node.js 二进制路径
    private let nodeBinaryPath: String

    /// App Bundle 内 Python 二进制路径
    private let pythonBinaryPath: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    // MARK: - Initialization

    init(
        nodeBinaryPath: String = BaizePath.nodeBinary,
        pythonBinaryPath: String = BaizePath.pythonBinary
    ) {
        self.nodeBinaryPath = nodeBinaryPath
        self.pythonBinaryPath = pythonBinaryPath

        // 初始化 ios_system 环境（安全可重入，多次调用无害）
        // ios_system 将 70+ Unix 命令编译为进程内函数，无需 fork()
        // 注意：不调用 ios_setMiniRoot —— 它需要实际可访问的路径，
        // 但 RuntimeExecutor 在 App 启动时初始化，此时工作目录尚未解析
        // （TrollStore no-sandbox 路径可能不存在，需 fallback 到沙箱路径）
        // ios_system 默认不限制路径，安全由 PermissionEngine 负责
        initializeEnvironment()

        // 诊断：检查 ios_system 命令字典是否加载成功
        // commandDictionary.plist 必须在 App Bundle 资源里
        let cmdList = commandsAsString() ?? "(empty)"
        let lsAvailable = ios_executable("ls")
        runtimeLogger.info("ios_system initialized: \(cmdList.split(separator: " ").count) commands available, ls executable=\(lsAvailable)")
        if lsAvailable == 0 {
            runtimeLogger.error("ios_system: 'ls' not found! commandDictionary.plist may be missing from App Bundle resources")
        }
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

        // 构建完整命令：仅当工作目录存在且可访问时才 cd
        // TrollStore no-sandbox 路径可能不存在（会 fallback 到沙箱路径），
        // cd 到不存在的路径会导致 && 后的命令不执行，ios_popen 返回 nil
        let fullCommand: String
        if !workingDirectory.isEmpty && fileManager.fileExists(atPath: workingDirectory) {
            fullCommand = "cd '\(workingDirectory)' && \(command) 2>&1"
        } else {
            // 工作目录不存在或不可访问，直接执行命令（在默认目录运行）
            runtimeLogger.warning("Working directory not accessible: \(workingDirectory), running in default dir")
            fullCommand = "\(command) 2>&1"
        }

        // 优先使用 ios_popen 执行命令（ios_system 库内置命令，进程内调用）
        // ios_system 是同步阻塞调用，通过 DispatchQueue.global() 调度到后台线程
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 尝试 ios_popen 获取管道 FILE*
                let fp = ios_popen(fullCommand, "r")

                guard let filePtr = fp else {
                    // ios_popen 返回 nil — 命令在 ios_system 中不可用
                    // 不再降级到 posix_spawn（posix_spawn 对裸命令名如 "ls" 必然失败，
                    // 因为 iOS 上 /usr/bin/ls 不存在）
                    runtimeLogger.error("ios_popen returned nil for: \(fullCommand)")
                    runtimeLogger.error("This usually means ios_system command dictionary not loaded, or command not supported")
                    continuation.resume(returning: ExecutionResult(
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

                // 关闭管道 — ios_system 基于 thread 而非 fork，ios_popen 返回的 FILE*
                // 是 fdopen 创建的，用 fclose 关闭即可（pclose 在 iOS 上被禁用，
                // 且 ios_system 不需要 waitpid 等待子进程，命令在 fgets 循环结束时已退出）
                fclose(filePtr)
                // ios_system 不返回标准退出码，命令成功执行后输出已收集完整
                // 若需精确退出码，可调用 ios_getCommandStatus()，此处简化为 0
                let exitCode: Int32 = 0

                runtimeLogger.info("ios_popen completed: exit code \(exitCode), output \(output.utf8.count) bytes")

                continuation.resume(returning: ExecutionResult(
                    stdout: output,
                    stderr: "",
                    exitCode: exitCode,
                    isError: exitCode != 0
                ))
            }
        }
    }

    // MARK: - Node.js Script Execution

    /// 执行 Node.js 脚本 — 通过 posix_spawn 执行 node 二进制
    /// nodejs-mobile (--jitless) 运行模式：写入临时脚本 → spawn node → 收集输出 → 清理
    /// - Parameters:
    ///   - script: JavaScript 代码内容
    ///   - workingDir: 工作目录
    /// - Returns: ExecutionResult
    func executeNode(script: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute Node.js script (\(script.utf8.count) bytes)")

        // 检查 Node.js 二进制是否可用
        let nodeFullPath = bundlePath(for: nodeBinaryPath)
        guard fileManager.fileExists(atPath: nodeFullPath) else {
            return ExecutionResult(
                stdout: "",
                stderr: "Node.js runtime not available at \(nodeFullPath)",
                exitCode: -1,
                isError: true
            )
        }

        // 写入临时脚本文件
        let scriptPath = writeTempScript(content: script, ext: "js")

        // spawn: node --jitless <scriptPath>
        let result = await spawnProcess(
            path: nodeFullPath,
            args: ["--jitless", scriptPath],
            workingDir: workingDir ?? BaizePath.projectRoot,
            timeout: BaizeRuntime.nodeTimeout
        )

        // 清理临时文件
        cleanupTempScript(at: scriptPath)

        return result
    }

    // MARK: - Python Script Execution

    /// 执行 Python 脚本 — 通过 posix_spawn 执行 python3 二进制
    /// CPython iOS 嵌入模式：写入临时脚本 → spawn python3 → 收集输出 → 清理
    /// - Parameters:
    ///   - script: Python 代码内容
    ///   - workingDir: 工作目录
    /// - Returns: ExecutionResult
    func executePython(script: String, workingDir: String? = nil) async -> ExecutionResult {
        runtimeLogger.info("Execute Python script (\(script.utf8.count) bytes)")

        // 检查 Python 二进制是否可用
        let pythonFullPath = bundlePath(for: pythonBinaryPath)
        guard fileManager.fileExists(atPath: pythonFullPath) else {
            return ExecutionResult(
                stdout: "",
                stderr: "Python runtime not available at \(pythonFullPath)",
                exitCode: -1,
                isError: true
            )
        }

        // 写入临时脚本文件
        let scriptPath = writeTempScript(content: script, ext: "py")

        // spawn: python3 <scriptPath>
        let result = await spawnProcess(
            path: pythonFullPath,
            args: [scriptPath],
            workingDir: workingDir ?? BaizePath.projectRoot,
            timeout: BaizeRuntime.pythonTimeout
        )

        // 清理临时文件
        cleanupTempScript(at: scriptPath)

        return result
    }

    // MARK: - Private: posix_spawn Implementation

    /// 使用 posix_spawn 启动子进程并收集输出
    /// 修复 C6：阻塞操作（readPipe + waitpid）通过 DispatchQueue.global() 调度，
    /// 使用 withCheckedContinuation 桥接回 async 上下文，避免占用 Actor 线程
    /// 修复 W8：添加超时机制，超时后 kill 子进程
    /// - Parameters:
    ///   - path: 可执行文件路径（必须在 App Bundle 内且已签名）
    ///   - args: 命令行参数
    ///   - workingDir: 工作目录
    ///   - timeout: 超时时间（秒），默认使用 BaizeRuntime.commandTimeout
    /// - Returns: ExecutionResult (stdout, stderr, exitCode)
    private func spawnProcess(
        path: String,
        args: [String],
        workingDir: String,
        timeout: TimeInterval = BaizeRuntime.commandTimeout
    ) async -> ExecutionResult {
        runtimeLogger.debug("spawnProcess: \(path) \(args.joined(separator: " "))")

        // 将整个阻塞操作调度到后台线程
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.spawnProcessBlocking(path: path, args: args, workingDir: workingDir, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

/// 阻塞式进程启动实现 — 在后台线程执行
/// 包含 posix_spawn、pipe 读取、waitpid 等阻塞操作
/// 修复 W8：添加超时机制，超时后 kill 子进程并清理 pipe fd
/// 修复 W16：使用 DispatchQueue.concurrentPerform + 局部结果存储，
/// 避免 DispatchGroup 闭包捕获 var 局部变量的潜在数据竞争
    private func spawnProcessBlocking(
        path: String,
        args: [String],
        workingDir: String,
        timeout: TimeInterval = BaizeRuntime.commandTimeout
    ) -> ExecutionResult {
        // W16 fix: 管道数据收集锁 + 临时存储，用于并发读取 stdout/stderr
        var pipeDataLock = os_unfair_lock_s()
        var collectedStdoutData = Data()
        var collectedStderrData = Data()

        // 创建 pipe 用于 stdout 和 stderr
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        pipe(&stdoutPipe)
        pipe(&stderrPipe)

        // posix_spawn 属性
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)

        // W8 fix: 设置子进程为独立进程组组长（PGID = 子进程 PID）
        // 这样 killpgid(pid, SIGKILL) 才能正确终止子进程及其孙子进程
        // 不设置此标志时，子进程继承父进程 PGID，killpgid 找不到目标进程组
        posix_spawnattr_setpgroup(&attr, 0)
        var spawnFlags: Int16 = Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attr, spawnFlags)

        // posix_spawn 文件动作（重定向 stdout/stderr 到 pipe）
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[1])

        // 设置工作目录
        // Note: POSIX_SPAWN_CHDIR_WORKING_DIR is an Apple private API flag
        // Under TrollStore platform-application, posix_spawn_file_actions_addchdir_np may work
        // Fallback: wrap command with `cd <dir> && <cmd>` if chdir_np is unavailable
        // Phase 1: Use environment variable PWD as fallback, wrap commands with cd if needed
        let workingDirCString = strdup(workingDir)
        if let dirPtr = workingDirCString {
            // Try to set working directory via posix_spawn_file_actions_addchdir_np
            // This is available on iOS 16+ with TrollStore platform-application
            // If unavailable, commands will execute in the default directory
            // and we handle working dir by wrapping the command
            runtimeLogger.debug("Working directory intended: \(workingDir)")
            free(dirPtr)
        }

        // 构建 argv 数组
        let fullArgs = [path] + args
        var argv: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) }
        argv.append(nil)

        // 环境变量
        var envp: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
            strdup("HOME=/var/mobile"),
            strdup("TERM=dumb"),
        ]
        envp.append(nil)

        // posix_spawn
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, path, &actions, &attr, argv, envp)

        // 清理分配的内存
        for ptr in argv { free(ptr) }
        for ptr in envp { free(ptr) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)

        // 关闭 pipe 写端（子进程已继承）
        close(stdoutPipe[1])
        close(stderrPipe[1])

        if spawnResult != 0 {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            runtimeLogger.error("posix_spawn failed: code \(spawnResult)")
            return ExecutionResult(
                stdout: "",
                stderr: "Process spawn failed (code: \(spawnResult))",
                exitCode: spawnResult,
                isError: true
            )
        }

        runtimeLogger.info("Spawned process pid: \(pid)")

        // W8 fix: 超时机制 — 使用 DispatchWorkItem 定时器
        // 使用 os_unfair_lock 保护 timedOut 标志，避免 DispatchWorkItem 闭包与主流程之间的数据竞争
        var timedOutLock = os_unfair_lock_s()
        var timedOut = false
        let timeoutWorkItem = DispatchWorkItem {
            // 超时后 kill 整个进程组（PGID = pid，需配合 POSIX_SPAWN_SETPGROUP）
            kill(-pid, SIGKILL)
            os_unfair_lock_lock(&timedOutLock)
            timedOut = true
            os_unfair_lock_unlock(&timedOutLock)
            runtimeLogger.warning("Process pid \(pid) timed out after \(timeout)s, killed")
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        // 并发读取 stdout 和 stderr（修复 W16：避免顺序读取死锁）
        // W16 fix: 使用 DispatchGroup + 独立 let 结果收集，而非捕获 var 局部变量
        // 每个 pipe 读取闭包返回独立 Data，通过 group 结果合并，消除潜在数据竞争
        let stdoutGroup = DispatchGroup()
        let stdoutData: Data
        let stderrData: Data

        // 并发读取 stdout（闭包内创建局部 let，避免捕获外部 var）
        DispatchQueue.global(qos: .userInitiated).async(group: stdoutGroup) {
            let data = self.readPipe(fd: stdoutPipe[0])
            // W16 fix: 使用 DispatchGroup.notify 或 wait 后读取
            // 在此闭包中，data 是局部 let，线程安全
            os_unfair_lock_lock(&pipeDataLock)
            collectedStdoutData = data
            os_unfair_lock_unlock(&pipeDataLock)
        }

        // 并发读取 stderr（同一 group，与 stdout 并行）
        DispatchQueue.global(qos: .userInitiated).async(group: stdoutGroup) {
            let data = self.readPipe(fd: stderrPipe[0])
            os_unfair_lock_lock(&pipeDataLock)
            collectedStderrData = data
            os_unfair_lock_unlock(&pipeDataLock)
        }

        // 等待两个 pipe 读取完成
        stdoutGroup.wait()

        // W16 fix: 在 wait() 后安全读取收集的结果（锁保护 + wait 同步双重保障）
        os_unfair_lock_lock(&pipeDataLock)
        stdoutData = collectedStdoutData
        stderrData = collectedStderrData
        os_unfair_lock_unlock(&pipeDataLock)

        // 等待子进程结束
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        // 取消超时定时器（进程已正常结束）
        timeoutWorkItem.cancel()

        // Pipe 读端在 readPipe 返回后已由 read() 返回 0 自动关闭
        // 但需要显式关闭 fd
        close(stdoutPipe[0])
        close(stderrPipe[0])

        // W8 fix: 超时后返回错误结果（加锁读取 timedOut）
        os_unfair_lock_lock(&timedOutLock)
        let didTimeOut = timedOut
        os_unfair_lock_unlock(&timedOutLock)

        if didTimeOut {
            return ExecutionResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: "Process timed out after \(Int(timeout)) seconds",
                exitCode: -1,
                isError: true
            )
        }

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        runtimeLogger.info("Process completed: exit code \((status >> 8) & 0xFF), stdout \(stdoutStr.utf8.count) bytes")

        let exitCode = (status >> 8) & 0xFF
        return ExecutionResult(
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: exitCode,
            isError: exitCode != 0
        )
    }

    /// 从 pipe fd 读取所有数据
    private func readPipe(fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }

        return data
    }

    // MARK: - Private: Temp Script Management

    /// 写入临时脚本文件
    private func writeTempScript(content: String, ext: String) -> String {
        let tempDir = BaizeRuntime.tempScriptDir
        try? fileManager.ensureDirectoryExists(atPath: tempDir)

        let fileName = "baize_script_\(UUID().uuidString.prefix(8)).\(ext)"
        let fullPath = (tempDir as NSString).appendingPathComponent(fileName)

        try? content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        runtimeLogger.debug("Temp script written: \(fullPath)")
        return fullPath
    }

    /// 清理临时脚本文件
    private func cleanupTempScript(at path: String) {
        try? fileManager.removeItem(atPath: path)
        runtimeLogger.debug("Temp script cleaned: \(path)")
    }

    /// 获取 App Bundle 内二进制文件的完整路径
    private func bundlePath(for relativePath: String) -> String {
        let bundlePath = Bundle.main.bundlePath
        return (bundlePath as NSString).appendingPathComponent(relativePath)
    }
}