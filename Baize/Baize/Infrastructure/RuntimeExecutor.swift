import Foundation
import ios_system

/// 代码执行引擎 — 策略模式重构
///
/// 对外接口不变（executeNode/executePython/executeCommand），内部通过策略委托：
/// - executeCommand → ios_system（进程内命令执行，不变）
/// - executeNode → NodeMobileStrategy → NodeRuntimeEngine → HTTP → Node.js（进程内）
/// - executePython → PythonSpawnStrategy → posix_spawn（暂保留，后续替换为 CPython Embedding）
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
    ///   - pythonStrategy: Python 执行策略（PythonSpawnStrategy）
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
        runtimeLogger.info("ios_system initialized: \(cmdList.split(separator: " ").count) commands available, ls executable=\(lsAvailable)")
        if lsAvailable == 0 {
            runtimeLogger.error("ios_system: 'ls' not found! commandDictionary.plist may be missing from App Bundle resources")
        }
    }

    /// 兼容旧调用的便捷初始化器 — 无 NodeRuntimeEngine 时使用降级策略
    /// 用于测试或未注入引擎时的 fallback
    convenience init() {
        self.init(
            nodeStrategy: NodeUnavailableStrategy(),
            pythonStrategy: PythonSpawnStrategy()
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

        // 构建完整命令：仅当工作目录存在且可访问时才 cd
        let fullCommand: String
        if !workingDirectory.isEmpty && fileManager.fileExists(atPath: workingDirectory) {
            fullCommand = "cd '\(workingDirectory)' && \(command) 2>&1"
        } else {
            runtimeLogger.warning("Working directory not accessible: \(workingDirectory), running in default dir")
            fullCommand = "\(command) 2>&1"
        }

        // 使用 ios_popen 执行命令（ios_system 库内置命令，进程内调用）
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fp = ios_popen(fullCommand, "r")

                guard let filePtr = fp else {
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

                fclose(filePtr)
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
