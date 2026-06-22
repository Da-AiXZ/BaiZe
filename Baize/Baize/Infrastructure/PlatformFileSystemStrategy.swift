import Foundation
import ios_system

// MARK: - File System Strategy Protocol

/// 文件系统写操作策略协议
/// T01 阶段定义协议 + 三种实现 stub；T02 填满 POSIX spawn / ios_system 实现
protocol FileSystemStrategy: Sendable {
    /// 写入文件内容（创建或覆盖）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要写入的内容
    func writeFile(at path: String, content: String) async throws

    /// 追加文件内容（JSONL 等追加写场景）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要追加的内容
    func appendFile(at path: String, content: String) async throws

    /// 精确字符串替换编辑
    /// - Parameters:
    ///   - path: 文件路径
    ///   - oldString: 要替换的原始字符串
    ///   - newString: 替换后的新字符串
    /// - Returns: 是否成功替换
    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool

    /// 创建目录
    /// - Parameter path: 目录路径
    func createDirectory(at path: String) async throws

    /// 删除文件或目录
    /// - Parameter path: 要删除的路径
    func deleteItem(at path: String) async throws
}

// MARK: - FileManager Strategy (默认实现，T01 填满)

/// 使用 FileManager 的文件系统策略
/// 作为默认策略，始终可用
struct FileManagerFileSystemStrategy: FileSystemStrategy {

    func writeFile(at path: String, content: String) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            baizeLogger.info("[FileManagerStrategy] Write file: \(path.fileName) (\(content.utf8.count) bytes)")
        } catch {
            throw BaizeError.fileSystemError("无法写入文件: \(path) — \(error.localizedDescription)")
        }
    }

    /// 追加文件内容（JSONL 追加写）
    func appendFile(at path: String, content: String) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw BaizeError.fileSystemError("无法打开文件进行追加: \(path)")
            }
            handle.seekToEndOfFile()
            handle.write(content.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        baizeLogger.info("[FileManagerStrategy] Append file: \(path.fileName) (\(content.utf8.count) bytes)")
    }

    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        guard !oldString.isEmpty else {
            throw BaizeError.fileSystemError("oldString 不能为空字符串")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }

        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw BaizeError.fileSystemError("无法读取文件: \(path) — \(error.localizedDescription)")
        }

        let nsContent = content as NSString
        var matchRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsContent.length)

        while searchRange.location < nsContent.length {
            let foundRange = nsContent.range(of: oldString, options: [], range: searchRange)
            if foundRange.location == NSNotFound { break }
            matchRanges.append(foundRange)
            searchRange = NSRange(
                location: foundRange.location + foundRange.length,
                length: nsContent.length - (foundRange.location + foundRange.length)
            )
        }

        if matchRanges.isEmpty {
            baizeLogger.warning("[FileManagerStrategy] Edit file: oldString not found in \(path.fileName)")
            return false
        }

        if matchRanges.count > 1 {
            throw BaizeError.fileSystemError(
                "oldString 在文件 \(path.fileName) 中有 \(matchRanges.count) 处匹配，请提供更多上下文使其唯一"
            )
        }

        let newContent = nsContent.replacingCharacters(in: matchRanges[0], with: newString)
        try await writeFile(at: path, content: newContent as String)
        baizeLogger.info("[FileManagerStrategy] Edit file: \(path.fileName) — replaced 1 occurrence")
        return true
    }

    func createDirectory(at path: String) async throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            baizeLogger.info("[FileManagerStrategy] Create directory: \(path)")
        } catch {
            throw BaizeError.fileSystemError("无法创建目录: \(path) — \(error.localizedDescription)")
        }
    }

    func deleteItem(at path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("要删除的项不存在: \(path)")
        }

        do {
            try FileManager.default.removeItem(atPath: path)
            baizeLogger.info("[FileManagerStrategy] Delete item: \(path.fileName)")
        } catch {
            throw BaizeError.fileSystemError("无法删除: \(path) — \(error.localizedDescription)")
        }
    }
}

// MARK: - POSIX Spawn Strategy (T02 填满)

/// 使用 POSIX spawn 调用外部二进制执行文件系统写操作
/// T02 真实实现：先写入临时文件，再通过 mv/mkdir/rm 等系统命令完成最终操作
struct PosixSpawnFileSystemStrategy: FileSystemStrategy {

    func writeFile(at path: String, content: String) async throws {
        let tempPath = makeTempPath()
        do {
            try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
            try ensureParentDirectoryExists(at: path)
            try moveItem(from: tempPath, to: path)
            baizeLogger.info("[PosixSpawnStrategy] Write file: \(path.fileName) (\(content.utf8.count) bytes)")
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    /// 追加文件内容：回退到 FileManager 实现（POSIX spawn 下重定向追加较复杂）
    func appendFile(at path: String, content: String) async throws {
        try await FileManagerFileSystemStrategy().appendFile(at: path, content: content)
        baizeLogger.info("[PosixSpawnStrategy] Append file (FileManager fallback): \(path.fileName) (\(content.utf8.count) bytes)")
    }

    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        guard !oldString.isEmpty else {
            throw BaizeError.fileSystemError("oldString 不能为空字符串")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }

        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw BaizeError.fileSystemError("无法读取文件: \(path) — \(error.localizedDescription)")
        }

        let nsContent = content as NSString
        var matchRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsContent.length)

        while searchRange.location < nsContent.length {
            let foundRange = nsContent.range(of: oldString, options: [], range: searchRange)
            if foundRange.location == NSNotFound { break }
            matchRanges.append(foundRange)
            searchRange = NSRange(
                location: foundRange.location + foundRange.length,
                length: nsContent.length - (foundRange.location + foundRange.length)
            )
        }

        if matchRanges.isEmpty {
            baizeLogger.warning("[PosixSpawnStrategy] Edit file: oldString not found in \(path.fileName)")
            return false
        }

        if matchRanges.count > 1 {
            throw BaizeError.fileSystemError(
                "oldString 在文件 \(path.fileName) 中有 \(matchRanges.count) 处匹配，请提供更多上下文使其唯一"
            )
        }

        let newContent = nsContent.replacingCharacters(in: matchRanges[0], with: newString)
        try await writeFile(at: path, content: newContent as String)
        baizeLogger.info("[PosixSpawnStrategy] Edit file: \(path.fileName) — replaced 1 occurrence")
        return true
    }

    func createDirectory(at path: String) async throws {
        try runPosixSpawn(
            executablePath: BaizeBinary.mkdirBinaryPath,
            arguments: ["mkdir", "-p", path]
        )
        baizeLogger.info("[PosixSpawnStrategy] Create directory: \(path)")
    }

    func deleteItem(at path: String) async throws {
        let rmPath = findExecutable(named: "rm") ?? "/bin/rm"
        try runPosixSpawn(executablePath: rmPath, arguments: ["rm", "-rf", path])
        baizeLogger.info("[PosixSpawnStrategy] Delete item: \(path.fileName)")
    }

    // MARK: - Private Helpers

    /// 生成唯一临时文件路径
    private func makeTempPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    }

    /// 确保目标路径的父目录存在（使用 bundle 内 mkdir 二进制）
    private func ensureParentDirectoryExists(at path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        try runPosixSpawn(
            executablePath: BaizeBinary.mkdirBinaryPath,
            arguments: ["mkdir", "-p", parent]
        )
    }

    /// 移动文件（使用系统 mv）
    private func moveItem(from source: String, to destination: String) throws {
        let mvPath = findExecutable(named: "mv") ?? "/bin/mv"
        try runPosixSpawn(executablePath: mvPath, arguments: ["mv", source, destination])
    }

    /// 在常见系统路径中查找可执行文件
    private func findExecutable(named name: String) -> String? {
        let candidates = ["/bin/\(name)", "/usr/bin/\(name)", "/usr/local/bin/\(name)"]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 使用 posix_spawn 执行外部命令并等待退出
    private func runPosixSpawn(executablePath: String, arguments: [String]) throws {
        guard FileManager.default.fileExists(atPath: executablePath) else {
            throw BaizeError.fileSystemError("可执行文件不存在: \(executablePath)")
        }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer {
            for ptr in argv {
                if let p = ptr { free(p) }
            }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executablePath, nil, nil, argv, nil)

        if spawnResult != 0 {
            throw BaizeError.fileSystemError("posix_spawn 失败 (errno=\(spawnResult)): \(executablePath)")
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)

        if status != 0 {
            throw BaizeError.fileSystemError(
                "命令退出码 \(status): \(executablePath) \(arguments.joined(separator: " "))"
            )
        }
    }
}

// MARK: - ios_system Strategy (T02 填满)

/// 使用 ios_system 框架执行文件系统写操作
/// T02 真实实现：通过 ios_popen 调用内置 mkdir/mv/rm 命令
struct IOSSystemFileSystemStrategy: FileSystemStrategy {

    func writeFile(at path: String, content: String) async throws {
        let tempPath = makeTempPath()
        do {
            try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
            try ensureParentDirectoryExists(at: path)
            try runIosSystem(command: "mv \"\(tempPath)\" \"\(path)\"")
            baizeLogger.info("[IOSSystemStrategy] Write file: \(path.fileName) (\(content.utf8.count) bytes)")
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    /// 追加文件内容：回退到 FileManager 实现（ios_system 的 shell 重定向支持不稳定）
    func appendFile(at path: String, content: String) async throws {
        try await FileManagerFileSystemStrategy().appendFile(at: path, content: content)
        baizeLogger.info("[IOSSystemStrategy] Append file (FileManager fallback): \(path.fileName) (\(content.utf8.count) bytes)")
    }

    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        guard !oldString.isEmpty else {
            throw BaizeError.fileSystemError("oldString 不能为空字符串")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }

        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw BaizeError.fileSystemError("无法读取文件: \(path) — \(error.localizedDescription)")
        }

        let nsContent = content as NSString
        var matchRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsContent.length)

        while searchRange.location < nsContent.length {
            let foundRange = nsContent.range(of: oldString, options: [], range: searchRange)
            if foundRange.location == NSNotFound { break }
            matchRanges.append(foundRange)
            searchRange = NSRange(
                location: foundRange.location + foundRange.length,
                length: nsContent.length - (foundRange.location + foundRange.length)
            )
        }

        if matchRanges.isEmpty {
            baizeLogger.warning("[IOSSystemStrategy] Edit file: oldString not found in \(path.fileName)")
            return false
        }

        if matchRanges.count > 1 {
            throw BaizeError.fileSystemError(
                "oldString 在文件 \(path.fileName) 中有 \(matchRanges.count) 处匹配，请提供更多上下文使其唯一"
            )
        }

        let newContent = nsContent.replacingCharacters(in: matchRanges[0], with: newString)
        try await writeFile(at: path, content: newContent as String)
        baizeLogger.info("[IOSSystemStrategy] Edit file: \(path.fileName) — replaced 1 occurrence")
        return true
    }

    func createDirectory(at path: String) async throws {
        try runIosSystem(command: "mkdir -p \"\(path)\"")
        baizeLogger.info("[IOSSystemStrategy] Create directory: \(path)")
    }

    func deleteItem(at path: String) async throws {
        try runIosSystem(command: "rm -rf \"\(path)\"")
        baizeLogger.info("[IOSSystemStrategy] Delete item: \(path.fileName)")
    }

    // MARK: - Private Helpers

    /// 生成唯一临时文件路径
    private func makeTempPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    }

    /// 确保目标路径的父目录存在
    private func ensureParentDirectoryExists(at path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        try runIosSystem(command: "mkdir -p \"\(parent)\"")
    }

    /// 使用 ios_system 的 ios_popen 执行命令
    private func runIosSystem(command: String) throws {
        let fp = ios_popen(command, "r")
        guard let filePtr = fp else {
            throw BaizeError.fileSystemError("ios_popen 失败: \(command)")
        }

        var buffer = [CChar](repeating: 0, count: 256)
        while fgets(&buffer, Int32(buffer.count), filePtr) != nil {
            // 消费输出，避免命令阻塞
        }
        fclose(filePtr)

        baizeLogger.info("[IOSSystemStrategy] Executed: \(command)")
    }
}
