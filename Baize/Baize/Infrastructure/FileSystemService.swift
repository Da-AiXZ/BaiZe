import Foundation

/// 文件系统服务 — 封装 FileManager，提供项目文件操作
/// TrollStore no-sandbox 环境下可访问 /var/mobile/Documents/Baize/ 及更广路径
/// 所有路径操作基于项目根目录（currentProjectPath）
/// 使用 class（引用语义）确保 setRootPath 变更即时传播到持有方
/// @unchecked Sendable：内部状态变更通过 Actor 隔离保证线程安全
class FileSystemService: @unchecked Sendable {

    // MARK: - Properties

    /// 项目根目录路径
    private var rootPath: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    // MARK: - Initialization

    init(rootPath: String = BaizePath.projectRoot) {
        self.rootPath = rootPath
        // 确保根目录存在
        try? ensureRootDirectory()
    }

    /// 更改项目根目录（class 引用语义，变更即时传播）
    func setRootPath(_ path: String) {
        rootPath = path
        try? ensureRootDirectory()
    }

    // MARK: - Read Operations

    /// 读取文件内容
    /// - Parameter path: 绝对文件路径
    /// - Returns: 文件内容字符串
    func readFile(at path: String) throws -> String {
        guard fileManager.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BaizeError.fileSystemError("无法读取文件: \(path)")
        }
        baizeLogger.info("Read file: \(path.fileName) (\(content.utf8.count) bytes)")
        return content
    }

    // MARK: - Write Operations

    /// 写入文件内容（创建或覆盖）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要写入的内容
    func writeFile(at path: String, content: String) throws {
        // 确保父目录存在
        let directory = path.directoryPath
        try fileManager.ensureDirectoryExists(atPath: directory)

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            baizeLogger.info("Write file: \(path.fileName) (\(content.utf8.count) bytes)")
        } catch {
            throw BaizeError.fileSystemError("无法写入文件: \(path) — \(error.localizedDescription)")
        }
    }

    /// 精确字符串替换编辑（类似 Claude Code 的 edit_file）
    /// - Parameters:
    ///   - path: 文件路径
    ///   - oldString: 要替换的原始字符串（必须精确匹配且唯一）
    ///   - newString: 替换后的新字符串
    /// - Returns: 是否成功找到并替换（true=替换成功，false=未找到匹配）
    /// W10 fix: 使用 NSString 精确范围搜索，多处匹配时返回错误而非全局替换
    func editFile(at path: String, oldString: String, newString: String) throws -> Bool {
        guard !oldString.isEmpty else {
            throw BaizeError.fileSystemError("oldString 不能为空字符串")
        }
        guard fileManager.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }

        let content = try readFile(at: path)
        let nsContent = content as NSString

        // 1. 搜索所有匹配范围
        var matchRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsContent.length)

        while searchRange.location < nsContent.length {
            let foundRange = nsContent.range(of: oldString, options: [], range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            matchRanges.append(foundRange)
            // 移动搜索起点到当前匹配之后，继续搜索
            searchRange = NSRange(
                location: foundRange.location + foundRange.length,
                length: nsContent.length - (foundRange.location + foundRange.length)
            )
        }

        // 2. 无匹配 → 返回 false
        if matchRanges.isEmpty {
            baizeLogger.warning("Edit file: oldString not found in \(path.fileName)")
            return false
        }

        // 3. 多处匹配 → 返回错误，要求用户提供更多上下文（Claude Code 行为）
        if matchRanges.count > 1 {
            baizeLogger.error("Edit file: oldString has \(matchRanges.count) matches in \(path.fileName), refusing ambiguous edit")
            throw BaizeError.fileSystemError(
                "oldString 在文件 \(path.fileName) 中有 \(matchRanges.count) 处匹配，请提供更多上下文使其唯一"
            )
        }

        // 4. 单处匹配 → 使用 replaceCharacters(in:with:) 精确替换该位置
        let targetRange = matchRanges[0]
        let newContent = nsContent.replacingCharacters(in: targetRange, with: newString)
        try writeFile(at: path, content: newContent as String)
        baizeLogger.info("Edit file: \(path.fileName) — replaced 1 occurrence at position \(targetRange.location)")
        return true
    }

    // MARK: - Directory Operations

    /// 列出目录内容
    /// - Parameter path: 目录路径（默认为项目根目录）
    /// - Returns: FileItem 数组
    func listDirectory(at path: String? = nil) throws -> [FileItem] {
        let dirPath = path ?? rootPath
        guard fileManager.fileExists(atPath: dirPath) else {
            // Try to create the directory first
            do {
                try fileManager.ensureDirectoryExists(atPath: dirPath)
            } catch {
                throw BaizeError.fileSystemError("目录不存在且无法创建: \(dirPath)")
            }
            // If creation succeeded but directory is still not there (edge case)
            guard fileManager.fileExists(atPath: dirPath) else {
                throw BaizeError.fileSystemError("目录不存在: \(dirPath)")
            }
            return [] // Return empty list for newly created directory
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: dirPath)
            var items: [FileItem] = []

            for name in contents {
                // 跳过隐藏文件（但允许 .baize 目录和 .git）
                if name.hasPrefix(".") && name != ".baize" && name != ".git" && name != BaizePath.projectConfigFile {
                    continue
                }

                let fullPath = (dirPath as NSString).appendingPathComponent(name)
                let isDir = fileManager.isDirectory(atPath: fullPath)
                let size = isDir ? 0 : (fileManager.fileSize(atPath: fullPath) ?? 0)
                let modDate = fileManager.fileModifiedDate(atPath: fullPath) ?? Date()

                let item = FileItem(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    children: nil, // 子节点延迟加载
                    size: size,
                    modifiedAt: modDate
                )
                items.append(item)
            }

            // 排序：目录在前，文件按名称排序
            items.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            return items
        } catch {
            throw BaizeError.fileSystemError("无法列出目录: \(dirPath) — \(error.localizedDescription)")
        }
    }

    // MARK: - Search Operations

    /// Glob 模式搜索文件名
    /// - Parameters:
    ///   - pattern: glob 模式（如 "*.swift", "src/**/*.ts"）
    ///   - path: 搜索起始目录（默认项目根目录）
    /// - Returns: 匹配的文件路径列表
    func searchFiles(pattern: String, in path: String? = nil) throws -> [String] {
        let searchPath = path ?? rootPath
        guard fileManager.fileExists(atPath: searchPath) else {
            throw BaizeError.fileSystemError("搜索目录不存在: \(searchPath)")
        }

        var results: [String] = []
        let globPattern = pattern.lowercased()

        // Phase 1: 递归遍历所有文件，简单 glob 匹配
        // Phase 2: 考虑使用更高效的搜索算法
        try enumerateFiles(at: searchPath) { filePath in
            let fileName = filePath.fileName.lowercased()
            if matchesGlobPattern(fileName: fileName, pattern: globPattern) {
                results.append(filePath)
            }
        }

        baizeLogger.info("Search files: pattern '\(pattern)' found \(results.count) results")
        return results
    }

    /// Grep 搜索文件内容（简单字符串匹配）
    /// - Parameters:
    ///   - pattern: 搜索关键词
    ///   - path: 搜索起始目录
    /// - Returns: SearchResult 数组（文件路径 + 匹配行号 + 匹配内容）
    func searchContent(pattern: String, in path: String? = nil) throws -> [SearchResult] {
        let searchPath = path ?? rootPath
        guard fileManager.fileExists(atPath: searchPath) else {
            throw BaizeError.fileSystemError("搜索目录不存在: \(searchPath)")
        }

        var results: [SearchResult] = []

        try enumerateFiles(at: searchPath) { filePath in
            // 跳过二进制文件和大文件
            guard let size = fileManager.fileSize(atPath: filePath), size < 1_000_000 else { return }
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(pattern) {
                    results.append(SearchResult(
                        filePath: filePath,
                        lineNumber: index + 1,
                        content: String(line).truncated(to: 200)
                    ))
                }
            }
        }

        baizeLogger.info("Search content: pattern '\(pattern)' found \(results.count) results")
        return results
    }

    // MARK: - Create/Delete Operations

    /// 创建目录
    func createDirectory(at path: String) throws {
        try fileManager.ensureDirectoryExists(atPath: path)
        baizeLogger.info("Create directory: \(path)")
    }

    /// 删除文件或目录
    func deleteItem(at path: String) throws {
        guard fileManager.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("要删除的项不存在: \(path)")
        }

        // 安全检查：不允许删除项目根目录
        if path == rootPath || path == BaizePath.projectRoot {
            throw BaizeError.permissionDenied("不允许删除项目根目录")
        }

        do {
            try fileManager.removeItem(atPath: path)
            baizeLogger.info("Delete item: \(path.fileName)")
        } catch {
            throw BaizeError.fileSystemError("无法删除: \(path) — \(error.localizedDescription)")
        }
    }

    /// 检查文件/目录是否存在
    func itemExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    // MARK: - Private Helpers

    /// 确保项目根目录存在
    private func ensureRootDirectory() throws {
        try fileManager.ensureDirectoryExists(atPath: rootPath)
    }

    /// 递归遍历目录中的所有文件
    private func enumerateFiles(at path: String, handler: (String) -> Void) throws {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return }

        for name in contents {
            if name.hasPrefix(".") && name != ".baize" && name != ".git" { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)

            if fileManager.isDirectory(atPath: fullPath) {
                try enumerateFiles(at: fullPath, handler: handler)
            } else {
                handler(fullPath)
            }
        }
    }

    /// 简单 glob 模式匹配（Phase 1）
    private func matchesGlobPattern(fileName: String, pattern: String) -> Bool {
        // 支持 * 和 ? 通配符
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        return fileName.range(of: regexPattern, options: .regularExpression) != nil
    }
}

// MARK: - File Item Model

/// 文件/目录条目模型
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileItem]? // 延迟加载
    let size: Int64
    let modifiedAt: Date

    /// 是否为 BAIZE.md 配置文件
    var isBaizeConfig: Bool { name == BaizePath.projectConfigFile }

    /// 文件扩展名
    var fileExtension: String { name.fileExtension }

    func hash(into hasher: inout Hasher) { hasher.combine(path) }
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.path == rhs.path }
}

// MARK: - Search Result Model

/// 内容搜索结果
struct SearchResult: Identifiable {
    let id = UUID()
    let filePath: String
    let lineNumber: Int
    let content: String
}

// MARK: - FileManager Extension

private extension FileManager {
    /// 判断路径是否为目录
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}