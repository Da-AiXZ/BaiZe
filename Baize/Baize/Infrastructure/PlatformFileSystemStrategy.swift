import Foundation

// MARK: - File System Strategy Protocol

/// 文件系统写操作策略协议
/// T01 阶段定义协议 + 三种实现 stub；T02 会填满 POSIX spawn / ios_system 实现
protocol FileSystemStrategy: Sendable {
    /// 写入文件内容（创建或覆盖）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要写入的内容
    func writeFile(at path: String, content: String) async throws

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
        try FileManager.default.ensureDirectoryExists(atPath: directory)

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            baizeLogger.info("[FileManagerStrategy] Write file: \(path.fileName) (\(content.utf8.count) bytes)")
        } catch {
            throw BaizeError.fileSystemError("无法写入文件: \(path) — \(error.localizedDescription)")
        }
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
            try FileManager.default.ensureDirectoryExists(atPath: path)
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

// MARK: - POSIX Spawn Strategy (T01 Stub)

/// 使用 POSIX spawn 调用外部二进制执行文件系统写操作
/// T01 阶段仅做占位，T02 填满真实实现
struct PosixSpawnFileSystemStrategy: FileSystemStrategy {

    func writeFile(at path: String, content: String) async throws {
        throw BaizeError.fileSystemError("POSIX spawn writeFile 尚未实现（T01 stub）")
    }

    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        throw BaizeError.fileSystemError("POSIX spawn editFile 尚未实现（T01 stub）")
    }

    func createDirectory(at path: String) async throws {
        throw BaizeError.fileSystemError("POSIX spawn createDirectory 尚未实现（T01 stub）")
    }

    func deleteItem(at path: String) async throws {
        throw BaizeError.fileSystemError("POSIX spawn deleteItem 尚未实现（T01 stub）")
    }
}

// MARK: - ios_system Strategy (T01 Stub)

/// 使用 ios_system 框架执行文件系统写操作
/// T01 阶段仅做占位，T02 填满真实实现
struct IOSSystemFileSystemStrategy: FileSystemStrategy {

    func writeFile(at path: String, content: String) async throws {
        throw BaizeError.fileSystemError("ios_system writeFile 尚未实现（T01 stub）")
    }

    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        throw BaizeError.fileSystemError("ios_system editFile 尚未实现（T01 stub）")
    }

    func createDirectory(at path: String) async throws {
        throw BaizeError.fileSystemError("ios_system createDirectory 尚未实现（T01 stub）")
    }

    func deleteItem(at path: String) async throws {
        throw BaizeError.fileSystemError("ios_system deleteItem 尚未实现（T01 stub）")
    }
}
