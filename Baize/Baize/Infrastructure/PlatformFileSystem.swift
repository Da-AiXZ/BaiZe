import Foundation

// MARK: - Platform File System Capabilities

/// 平台文件系统能力探测结果
struct FileSystemCapabilities: Sendable, CustomStringConvertible {
    let fileManager: Bool
    let posixSpawn: Bool
    let iosSystem: Bool

    var description: String {
        "fileManager=\(fileManager), posixSpawn=\(posixSpawn), iosSystem=\(iosSystem)"
    }
}

// MARK: - Platform File System

/// 平台文件系统 actor — 统一文件系统操作入口
/// T01 设计原则：
///   - 读操作始终使用 FileManager（iOS 原生、安全、可预测）
///   - 写操作通过可插拔的 `FileSystemStrategy` 执行，默认 `FileManagerFileSystemStrategy`
///   - T02 会用 `PlatformFileSystem` 替换旧的 `FileSystemService`
actor PlatformFileSystem {

    // MARK: - Properties

    /// 项目根目录路径
    private var rootPath: String

    /// 当前写操作策略
    private var strategy: FileSystemStrategy

    // MARK: - Initialization

    /// 创建 PlatformFileSystem
    /// - Parameters:
    ///   - rootPath: 项目根目录
    ///   - strategyType: 初始写操作策略（默认 .fileManager）
    init(rootPath: String, strategyType: FileSystemStrategyType = .fileManager) {
        self.rootPath = rootPath
        self.strategy = strategyType.strategyInstance
        baizeLogger.info("PlatformFileSystem initialized at \(rootPath) with strategy \(strategyType.rawValue)")
    }

    // MARK: - Configuration

    /// 更改项目根目录
    /// - Parameter path: 新的项目根目录绝对路径
    func setRootPath(_ path: String) {
        rootPath = path
        baizeLogger.info("PlatformFileSystem: rootPath updated to \(path)")
    }

    /// 切换写操作策略
    /// - Parameter type: 策略类型
    func setStrategy(_ type: FileSystemStrategyType) {
        strategy = type.strategyInstance
        baizeLogger.info("PlatformFileSystem: strategy switched to \(type.rawValue)")
    }

    /// 获取当前策略类型
    func currentStrategy() -> FileSystemStrategyType {
        if strategy is PosixSpawnFileSystemStrategy {
            return .posixSpawn
        } else if strategy is IOSSystemFileSystemStrategy {
            return .iosSystem
        }
        return .fileManager
    }

    // MARK: - Read Operations (始终使用 FileManager)

    /// 读取文件内容
    /// - Parameter path: 绝对文件路径
    /// - Returns: 文件内容字符串
    func readFile(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BaizeError.fileSystemError("文件不存在: \(path)")
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BaizeError.fileSystemError("无法读取文件: \(path)")
        }
        baizeLogger.info("[PlatformFileSystem] Read file: \(path.fileName) (\(content.utf8.count) bytes)")
        return content
    }

    /// 列出目录内容
    /// - Parameter path: 目录路径（默认为项目根目录）
    /// - Returns: FileItem 数组
    func listDirectory(at path: String? = nil) throws -> [FileItem] {
        let dirPath = path ?? rootPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: dirPath) else {
            do {
                try fm.ensureDirectoryExists(atPath: dirPath)
            } catch {
                throw BaizeError.fileSystemError("目录不存在且无法创建: \(dirPath)")
            }
            guard fm.fileExists(atPath: dirPath) else {
                throw BaizeError.fileSystemError("目录不存在: \(dirPath)")
            }
            return []
        }

        do {
            let contents = try fm.contentsOfDirectory(atPath: dirPath)
            var items: [FileItem] = []

            for name in contents {
                if name.hasPrefix(".") && name != ".baize" && name != ".git" && name != BaizePath.projectConfigFile {
                    continue
                }

                let fullPath = (dirPath as NSString).appendingPathComponent(name)
                let isDir = PlatformFileSystem.isDirectory(atPath: fullPath)
                let size = isDir ? 0 : (fm.fileSize(atPath: fullPath) ?? 0)
                let modDate = fm.fileModifiedDate(atPath: fullPath) ?? Date()

                items.append(FileItem(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    children: nil,
                    size: size,
                    modifiedAt: modDate
                ))
            }

            items.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            return items
        } catch {
            throw BaizeError.fileSystemError("无法列出目录: \(dirPath) — \(error.localizedDescription)")
        }
    }

    /// 搜索文件名（glob 匹配）
    /// - Parameters:
    ///   - pattern: glob 模式
    ///   - path: 搜索起始目录
    /// - Returns: 匹配文件路径列表
    func searchFiles(pattern: String, in path: String? = nil) throws -> [String] {
        let searchPath = path ?? rootPath
        guard FileManager.default.fileExists(atPath: searchPath) else {
            throw BaizeError.fileSystemError("搜索目录不存在: \(searchPath)")
        }

        var results: [String] = []
        let globPattern = pattern.lowercased()

        try enumerateFiles(at: searchPath) { filePath in
            let fileName = filePath.fileName.lowercased()
            if matchesGlobPattern(fileName: fileName, pattern: globPattern) {
                results.append(filePath)
            }
        }

        baizeLogger.info("[PlatformFileSystem] Search files: pattern '\(pattern)' found \(results.count) results")
        return results
    }

    /// 搜索文件内容
    /// - Parameters:
    ///   - pattern: 搜索关键词
    ///   - path: 搜索起始目录
    /// - Returns: SearchResult 数组
    func searchContent(pattern: String, in path: String? = nil) throws -> [SearchResult] {
        let searchPath = path ?? rootPath
        guard FileManager.default.fileExists(atPath: searchPath) else {
            throw BaizeError.fileSystemError("搜索目录不存在: \(searchPath)")
        }

        var results: [SearchResult] = []
        let fm = FileManager.default

        try enumerateFiles(at: searchPath) { filePath in
            guard let size = fm.fileSize(atPath: filePath), size < 1_000_000 else { return }
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

        baizeLogger.info("[PlatformFileSystem] Search content: pattern '\(pattern)' found \(results.count) results")
        return results
    }

    /// 检查文件/目录是否存在
    /// - Parameter path: 要检查的路径
    /// - Returns: 是否存在
    func itemExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Write Operations (通过 FileSystemStrategy)

    /// 写入文件内容（创建或覆盖）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要写入的内容
    func writeFile(at path: String, content: String) async throws {
        try await strategy.writeFile(at: path, content: content)
    }

    /// 精确字符串替换编辑
    /// - Parameters:
    ///   - path: 文件路径
    ///   - oldString: 要替换的原始字符串
    ///   - newString: 替换后的新字符串
    /// - Returns: 是否成功替换
    func editFile(at path: String, oldString: String, newString: String) async throws -> Bool {
        try await strategy.editFile(at: path, oldString: oldString, newString: newString)
    }

    /// 创建目录
    /// - Parameter path: 目录路径
    func createDirectory(at path: String) async throws {
        try await strategy.createDirectory(at: path)
    }

    /// 删除文件或目录
    /// - Parameter path: 要删除的路径
    func deleteItem(at path: String) async throws {
        // 安全检查：不允许删除项目根目录
        if path == rootPath || path == BaizePath.projectRoot {
            throw BaizeError.permissionDenied("不允许删除项目根目录")
        }
        try await strategy.deleteItem(at: path)
    }

    // MARK: - Capability Probing

    /// 探测平台可用的文件系统能力
    /// T01：FileManager 始终可用；POSIX spawn 需要 git + mkdir 二进制存在；ios_system 默认 false
    /// - Returns: FileSystemCapabilities
    func probe() async -> FileSystemCapabilities {
        let fm = FileManager.default
        let gitAvailable = fm.fileExists(atPath: BaizeBinary.gitBinaryPath)
        let mkdirAvailable = fm.fileExists(atPath: BaizeBinary.mkdirBinaryPath)
        let caAvailable = fm.fileExists(atPath: BaizeBinary.caBundlePath)

        let posixAvailable = gitAvailable && mkdirAvailable && caAvailable
        baizeLogger.info(
            "[PlatformFileSystem] Probed capabilities: git=\(gitAvailable), mkdir=\(mkdirAvailable), ca=\(caAvailable)"
        )

        return FileSystemCapabilities(
            fileManager: true,
            posixSpawn: posixAvailable,
            iosSystem: false
        )
    }

    // MARK: - Private Helpers

    /// 递归遍历目录中的所有文件
    private func enumerateFiles(at path: String, handler: (String) -> Void) throws {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }

        for name in contents {
            if name.hasPrefix(".") && name != ".baize" && name != ".git" { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)

            if PlatformFileSystem.isDirectory(atPath: fullPath) {
                try enumerateFiles(at: fullPath, handler: handler)
            } else {
                handler(fullPath)
            }
        }
    }

    /// 判断路径是否为目录（避免依赖 FileSystemService 的私有扩展）
    private static func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// 简单 glob 模式匹配
    private func matchesGlobPattern(fileName: String, pattern: String) -> Bool {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        return fileName.range(of: regexPattern, options: .regularExpression) != nil
    }
}

// MARK: - Strategy Type to Instance

extension FileSystemStrategyType {
    /// 根据策略类型创建对应策略实例
    fileprivate var strategyInstance: FileSystemStrategy {
        switch self {
        case .fileManager:
            return FileManagerFileSystemStrategy()
        case .posixSpawn:
            return PosixSpawnFileSystemStrategy()
        case .iosSystem:
            return IOSSystemFileSystemStrategy()
        }
    }
}
