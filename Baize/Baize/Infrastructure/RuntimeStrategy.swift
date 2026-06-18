import Foundation

// MARK: - RuntimeStrategy Protocol

/// 运行时执行策略协议 — 统一脚本执行接口
///
/// 不同运行时（Node.js、Python）实现此协议，
/// RuntimeExecutor 通过策略模式委托执行。
protocol RuntimeStrategy: Sendable {
    /// 执行脚本
    /// - Parameters:
    ///   - script: 脚本代码内容
    ///   - workingDir: 工作目录（可选）
    /// - Returns: 执行结果
    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult
}

// MARK: - NodeMobileStrategy

/// Node.js 进程内执行策略 — 通过 nodejs-mobile HTTP server 执行脚本
///
/// 委托 NodeRuntimeEngine 发送 HTTP POST 请求到本地 Node.js server，
/// server 使用 vm.runInThisContext() 执行脚本并返回 stdout/stderr。
struct NodeMobileStrategy: RuntimeStrategy {

    /// Node.js 运行时引擎实例
    private let engine: NodeRuntimeEngine

    /// 创建 NodeMobileStrategy
    /// - Parameter engine: 已启动的 NodeRuntimeEngine 实例
    init(engine: NodeRuntimeEngine) {
        self.engine = engine
    }

    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult {
        return await engine.executeScript(
            script: script,
            workingDir: workingDir,
            timeout: BaizeRuntime.nodeTimeout
        )
    }
}

// MARK: - NodeUnavailableStrategy

/// 降级策略 — Node 引擎未注入时返回友好错误
///
/// 当 BaizeApp 未能创建 NodeRuntimeEngine 时（如 framework 缺失），
/// RuntimeExecutor 使用此策略，所有 execute 调用返回错误信息。
struct NodeUnavailableStrategy: RuntimeStrategy {

    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult {
        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: "Node.js 运行时未初始化。请重启 App。如问题持续，请检查 NodeMobile.framework 是否正确嵌入。",
            exitCode: -1,
            isError: true
        )
    }
}

// MARK: - PythonEmbeddingStrategy

/// Python 嵌入模式执行策略 — 通过 CPython HTTP server 执行脚本
///
/// 委托 PythonRuntimeEngine 发送 HTTP POST 请求到本地 Python server，
/// server 使用 exec() 执行脚本并返回 stdout/stderr。
struct PythonEmbeddingStrategy: RuntimeStrategy {

    /// Python 运行时引擎实例
    private let engine: PythonRuntimeEngine

    /// 创建 PythonEmbeddingStrategy
    /// - Parameter engine: 已启动的 PythonRuntimeEngine 实例
    init(engine: PythonRuntimeEngine) {
        self.engine = engine
    }

    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult {
        return await engine.executeScript(
            script: script,
            workingDir: workingDir,
            timeout: BaizeRuntime.pythonTimeout
        )
    }
}

// MARK: - PythonUnavailableStrategy

/// 降级策略 — Python 引擎未注入时返回友好错误
///
/// 当 BaizeApp 未能创建 PythonRuntimeEngine 时（如 framework 缺失），
/// RuntimeExecutor 使用此策略，所有 execute 调用返回错误信息。
struct PythonUnavailableStrategy: RuntimeStrategy {

    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult {
        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: "Python 运行时未初始化。请重启 App。如问题持续，请检查 Python.framework 是否正确嵌入，以及 install_python Build Phase 是否正常运行。",
            exitCode: -1,
            isError: true
        )
    }
}

// MARK: - PythonSpawnStrategy

/// Python 执行策略 — 保留现有 posix_spawn 逻辑
///
/// P2 阶段不改动 Python 执行方式，后续将替换为 CPython Embedding。
/// 此策略从 RuntimeExecutor 迁移了 posix_spawn + pipe + waitpid 逻辑。
struct PythonSpawnStrategy: RuntimeStrategy {

    /// App Bundle 内 Python 二进制路径
    private let pythonBinaryPath: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    /// 创建 PythonSpawnStrategy
    /// - Parameter pythonBinaryPath: Python 二进制在 App Bundle 中的相对路径
    init(pythonBinaryPath: String = BaizePath.pythonBinary) {
        self.pythonBinaryPath = pythonBinaryPath
    }

    // MARK: - RuntimeStrategy

    func execute(script: String, workingDir: String?) async -> RuntimeExecutor.ExecutionResult {
        runtimeLogger.info("PythonSpawnStrategy: execute script (\(script.utf8.count) bytes)")

        // 检查 Python 二进制是否可用
        let pythonFullPath = bundlePath(for: pythonBinaryPath)
        guard fileManager.fileExists(atPath: pythonFullPath) else {
            return RuntimeExecutor.ExecutionResult(
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
    /// - Parameters:
    ///   - path: 可执行文件路径（必须在 App Bundle 内且已签名）
    ///   - args: 命令行参数
    ///   - workingDir: 工作目录
    ///   - timeout: 超时时间（秒）
    /// - Returns: ExecutionResult
    private func spawnProcess(
        path: String,
        args: [String],
        workingDir: String,
        timeout: TimeInterval = BaizeRuntime.commandTimeout
    ) async -> RuntimeExecutor.ExecutionResult {
        runtimeLogger.debug("PythonSpawnStrategy.spawnProcess: \(path) \(args.joined(separator: " "))")

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
    private func spawnProcessBlocking(
        path: String,
        args: [String],
        workingDir: String,
        timeout: TimeInterval = BaizeRuntime.commandTimeout
    ) -> RuntimeExecutor.ExecutionResult {
        // 管道数据收集锁 + 临时存储
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

        // 设置子进程为独立进程组组长（PGID = 子进程 PID）
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
        let workingDirCString = strdup(workingDir)
        if let dirPtr = workingDirCString {
            runtimeLogger.debug("PythonSpawnStrategy: working directory intended: \(workingDir)")
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
            runtimeLogger.error("PythonSpawnStrategy: posix_spawn failed: code \(spawnResult)")
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "Process spawn failed (code: \(spawnResult))",
                exitCode: spawnResult,
                isError: true
            )
        }

        runtimeLogger.info("PythonSpawnStrategy: spawned process pid: \(pid)")

        // 超时机制 — 使用 DispatchWorkItem 定时器
        var timedOutLock = os_unfair_lock_s()
        var timedOut = false
        let timeoutWorkItem = DispatchWorkItem {
            kill(-pid, SIGKILL)
            os_unfair_lock_lock(&timedOutLock)
            timedOut = true
            os_unfair_lock_unlock(&timedOutLock)
            runtimeLogger.warning("PythonSpawnStrategy: process pid \(pid) timed out after \(timeout)s, killed")
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        // 并发读取 stdout 和 stderr
        let stdoutGroup = DispatchGroup()
        let stdoutData: Data
        let stderrData: Data

        DispatchQueue.global(qos: .userInitiated).async(group: stdoutGroup) {
            let data = self.readPipe(fd: stdoutPipe[0])
            os_unfair_lock_lock(&pipeDataLock)
            collectedStdoutData = data
            os_unfair_lock_unlock(&pipeDataLock)
        }

        DispatchQueue.global(qos: .userInitiated).async(group: stdoutGroup) {
            let data = self.readPipe(fd: stderrPipe[0])
            os_unfair_lock_lock(&pipeDataLock)
            collectedStderrData = data
            os_unfair_lock_unlock(&pipeDataLock)
        }

        stdoutGroup.wait()

        os_unfair_lock_lock(&pipeDataLock)
        stdoutData = collectedStdoutData
        stderrData = collectedStderrData
        os_unfair_lock_unlock(&pipeDataLock)

        // 等待子进程结束
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        // 取消超时定时器
        timeoutWorkItem.cancel()

        close(stdoutPipe[0])
        close(stderrPipe[0])

        // 检查是否超时
        os_unfair_lock_lock(&timedOutLock)
        let didTimeOut = timedOut
        os_unfair_lock_unlock(&timedOutLock)

        if didTimeOut {
            return RuntimeExecutor.ExecutionResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: "Process timed out after \(Int(timeout)) seconds",
                exitCode: -1,
                isError: true
            )
        }

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        runtimeLogger.info("PythonSpawnStrategy: process completed: exit code \((status >> 8) & 0xFF), stdout \(stdoutStr.utf8.count) bytes")

        let exitCode = (status >> 8) & 0xFF
        return RuntimeExecutor.ExecutionResult(
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
        runtimeLogger.debug("PythonSpawnStrategy: temp script written: \(fullPath)")
        return fullPath
    }

    /// 清理临时脚本文件
    private func cleanupTempScript(at path: String) {
        try? fileManager.removeItem(atPath: path)
        runtimeLogger.debug("PythonSpawnStrategy: temp script cleaned: \(path)")
    }

    /// 获取 App Bundle 内二进制文件的完整路径
    private func bundlePath(for relativePath: String) -> String {
        let bundlePath = Bundle.main.bundlePath
        return (bundlePath as NSString).appendingPathComponent(relativePath)
    }
}
