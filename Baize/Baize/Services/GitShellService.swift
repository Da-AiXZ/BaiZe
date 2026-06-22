import Foundation
import Darwin

// MARK: - Git Shell Result

/// Git 命令执行结果
struct GitShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    /// 合并 stdout 与 stderr 的输出（优先 stdout，stderr 非空时追加）
    var combinedOutput: String {
        var output = stdout
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += stderr
        }
        return output
    }
}

// MARK: - Git Shell Service

/// T03: 通过 bundle 内 git 二进制执行远程操作（fetch / push / pull / clone）
/// 使用 POSIX spawn 调用静态编译的 iOS arm64 git 二进制，
/// 并通过环境变量注入 CA 证书、禁用终端提示、设置 HOME 目录，
/// 从而彻底解决 iOS libgit2 + OpenSSL 的 TLS 证书问题。
actor GitShellService {

    // MARK: - Properties

    /// 本地仓库路径（作为 git 命令的 working directory）
    private let repositoryPath: String

    /// Keychain 服务（读取 GitHub Token）
    private let keychainService: KeychainService

    /// Git 二进制可执行文件路径（bundle 内）
    private let gitBinaryPath: String

    /// CA 证书包路径（bundle 内）
    private let caBundlePath: String

    // MARK: - Initialization

    /// 创建 GitShellService
    /// - Parameters:
    ///   - repositoryPath: 本地仓库路径
    ///   - keychainService: Keychain 服务
    ///   - gitBinaryPath: git 二进制路径（默认使用 bundle 内路径）
    ///   - caBundlePath: CA 证书包路径（默认使用 bundle 内路径）
    init(
        repositoryPath: String,
        keychainService: KeychainService,
        gitBinaryPath: String = BaizeBinary.gitBinaryPath,
        caBundlePath: String = BaizeBinary.caBundlePath
    ) {
        self.repositoryPath = repositoryPath
        self.keychainService = keychainService
        self.gitBinaryPath = gitBinaryPath
        self.caBundlePath = caBundlePath
    }

    // MARK: - Generic Git Command Execution

    /// 执行任意 git 命令并返回输出
    /// 供 `ExecuteCommandTool` 路由 git 命令，确保 AI 看到真实远程输出。
    /// - Parameters:
    ///   - arguments: git 子命令及参数（不含 `git` 本身）
    ///   - workingDirectory: 工作目录（默认 repositoryPath）
    /// - Returns: GitShellResult（退出码 + stdout + stderr）
    func executeGitCommand(_ arguments: [String], workingDirectory: String? = nil) async throws -> GitShellResult {
        try ensureGitBinaryExists()
        let workDir = workingDirectory ?? repositoryPath
        try ensureDirectoryExists(at: workDir)

        // 准备 .netrc 凭据（写入项目目录，HOME 指向此处）
        try prepareNetrc()

        let result = try runGit(arguments: arguments, workingDirectory: workDir)
        baizeLogger.info("[GitShellService] git \(arguments.joined(separator: " ")) -> exitCode=\(result.exitCode)")
        return result
    }

    /// 执行任意 git 命令（字符串形式，供 ExecuteCommandTool 使用）
    /// - Parameter command: 完整的 git 命令字符串（如 "git fetch origin"）
    /// - Returns: GitShellResult
    func executeGitCommand(_ command: String) async throws -> GitShellResult {
        var parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "git" else {
            throw GitError.operationFailed("命令必须以 'git' 开头: \(command)")
        }
        parts.removeFirst()
        return try await executeGitCommand(parts)
    }

    // MARK: - Remote Operations

    /// 从远程仓库 fetch 更新
    /// - Parameter remote: 远程名称（默认 origin）
    /// - Returns: 接收到的字节数（用于兼容旧的 GitFetchResult）
    func fetch(remote: String = "origin") async throws -> GitFetchResult {
        let result = try await executeGitCommand(["fetch", remote])
        if result.exitCode != 0 {
            throw GitError.operationFailed("git fetch 失败: \(result.combinedOutput)")
        }
        // 估算接收字节数：统计输出中常见的 "Receiving objects" 或直接用 0
        let receivedBytes = parseReceivedBytes(from: result.stdout)
        return GitFetchResult(updatedBranches: 1, receivedBytes: receivedBytes)
    }

    /// 推送当前分支到远程
    /// - Parameter force: 是否强制推送
    func push(force: Bool = false) async throws {
        var args = ["push"]
        if force { args.append("--force") }
        let result = try await executeGitCommand(args)
        if result.exitCode != 0 {
            throw GitError.operationFailed("git push 失败: \(result.combinedOutput)")
        }
    }

    /// 拉取远程更新并合并到当前分支
    /// - Returns: GitMergeResult（fast-forward 标记由输出判断）
    func pull() async throws -> GitMergeResult {
        let result = try await executeGitCommand(["pull"])
        if result.exitCode != 0 {
            throw GitError.operationFailed("git pull 失败: \(result.combinedOutput)")
        }
        let isFastForward = result.stdout.contains("Fast-forward") ||
                            result.stdout.contains("Updating")
        return GitMergeResult(success: true, conflictFiles: [], isFastForward: isFastForward)
    }

    /// 克隆远程仓库到指定路径
    /// - Parameters:
    ///   - url: 远程仓库 URL（HTTPS 或 SSH）
    ///   - toPath: 本地目标路径
    func clone(url: String, toPath: String) async throws {
        try ensureDirectoryExists(at: (toPath as NSString).deletingLastPathComponent)

        // 克隆 URL 注入凭据（token 作为密码）
        let cloneURL = injectCredentialsIfNeeded(into: url)
        let result = try await executeGitCommand(["clone", cloneURL, toPath])
        if result.exitCode != 0 {
            throw GitError.cloneFailed("git clone 失败: \(result.combinedOutput)")
        }
    }

    // MARK: - Private Helpers

    /// 检查 git 二进制是否存在
    private func ensureGitBinaryExists() throws {
        guard FileManager.default.fileExists(atPath: gitBinaryPath) else {
            throw GitError.operationFailed("git 二进制不存在: \(gitBinaryPath)。请在 T03 阶段替换为真实静态编译的 iOS arm64 git 二进制。")
        }
    }

    /// 确保目录存在
    private func ensureDirectoryExists(at path: String) throws {
        guard !path.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    }

    /// 准备环境变量
    private func prepareEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_SSL_CAINFO"] = caBundlePath
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOME"] = repositoryPath
        return env
    }

    /// 准备 .netrc 凭据文件（写入项目目录，供 curl 读取）
    /// 注意：当前实现会覆盖项目目录中的 .netrc（如存在）。
    /// 若后续需要更安全方案，可改用 keychain + 临时 credential helper。
    private func prepareNetrc() throws {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else { return }
        let netrcPath = (repositoryPath as NSString).appendingPathComponent(".netrc")
        let netrcContent = "default\nlogin git\npassword \(token)\n"
        try netrcContent.write(toFile: netrcPath, atomically: true, encoding: .utf8)
    }

    /// 将凭据注入 URL（用于 clone 等直接提供 URL 的场景）
    private func injectCredentialsIfNeeded(into url: String) -> String {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else { return url }
        guard url.hasPrefix("https://") else { return url }
        // 避免重复注入
        if url.contains("@") { return url }
        return url.replacingOccurrences(of: "https://", with: "https://git:\(token)@")
    }

    /// 使用 POSIX spawn 执行 git 命令并捕获输出
    private func runGit(arguments: [String], workingDirectory: String) throws -> GitShellResult {
        var pipeStdout = [Int32](repeating: 0, count: 2)
        var pipeStderr = [Int32](repeating: 0, count: 2)
        pipe(&pipeStdout)
        pipe(&pipeStderr)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeStdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeStderr[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeStdout[0])
        posix_spawn_file_actions_addclose(&fileActions, pipeStderr[0])
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(gitBinaryPath)] + arguments.map { strdup($0) }
        argv.append(nil)
        defer {
            for ptr in argv { if let p = ptr { free(p) } }
        }

        let env = prepareEnvironment()
        let envStrings = env.map { "\($0)=\($1)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for ptr in envp { if let p = ptr { free(p) } }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, gitBinaryPath, &fileActions, nil, argv, envp)

        // 关闭子进程不会使用的写端已在 fileActions 中声明，但此处再关闭本进程副本
        close(pipeStdout[1])
        close(pipeStderr[1])

        if spawnResult != 0 {
            close(pipeStdout[0])
            close(pipeStderr[0])
            throw GitError.operationFailed("posix_spawn 失败 (errno=\(spawnResult)): \(gitBinaryPath)")
        }

        let stdoutData = readFileDescriptor(pipeStdout[0])
        let stderrData = readFileDescriptor(pipeStderr[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return GitShellResult(exitCode: status, stdout: stdout, stderr: stderr)
    }

    /// 从文件描述符读取全部数据
    private func readFileDescriptor(_ fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let bytesRead = read(fd, &buffer, bufferSize)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }
        close(fd)
        return data
    }

    /// 从 git fetch 输出中估算接收字节数
    private func parseReceivedBytes(from output: String) -> Int {
        // 匹配 "Receiving objects: 100% (1234/1234), 456.78 KiB | 123.45 MiB/s"
        // 也尝试匹配 "remote: Enumerating objects: 123"
        let patterns = [
            #"[\d\.]+\s*(KiB|MiB|GiB|B)\s*\|"#,
            #"remote:\s*Enumerating objects:\s*(\d+)"#,
        ]
        for pattern in patterns {
            if let range = output.range(of: pattern, options: .regularExpression) {
                let match = String(output[range])
                if let size = parseSizeString(match) {
                    return size
                }
            }
        }
        return 0
    }

    /// 解析 "456.78 KiB" 这类字符串为字节数
    private func parseSizeString(_ text: String) -> Int? {
        let numberPattern = #"[\d\.]+"#
        let unitPattern = #"(KiB|MiB|GiB|B)"#
        guard let numberRange = text.range(of: numberPattern, options: .regularExpression),
              let unitRange = text.range(of: unitPattern, options: .regularExpression) else {
            return nil
        }
        guard let number = Double(String(text[numberRange])) else { return nil }
        let unit = String(text[unitRange])
        switch unit {
        case "B": return Int(number)
        case "KiB": return Int(number * 1024)
        case "MiB": return Int(number * 1024 * 1024)
        case "GiB": return Int(number * 1024 * 1024 * 1024)
        default: return nil
        }
    }
}
