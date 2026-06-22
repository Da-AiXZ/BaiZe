import Foundation

/// 文件系统服务 — 平台文件系统的兼容包装层
/// T02：所有写操作统一转发到 PlatformFileSystem，读操作通过 PlatformFileSystem 的 FileManager 实现
/// 为保持与现有同步调用点的兼容，当前保留同步方法签名，内部通过 DispatchSemaphore 等待 actor 调用
/// 后续新代码建议直接使用 PlatformFileSystem 的 async API
class FileSystemService: @unchecked Sendable {

    // MARK: - Properties

    /// 项目根目录路径
    private var rootPath: String

    /// 平台文件系统统一入口（actor）
    /// T05: 改为 internal，允许 SubAgentContext 继承父 Agent 的文件系统策略
    let platformFileSystem: PlatformFileSystem

    // MARK: - Initialization

    /// 创建 FileSystemService
    /// - Parameters:
    ///   - rootPath: 项目根目录
    ///   - platformFileSystem: 可选的外部 PlatformFileSystem 实例；未传入则新建
    init(rootPath: String = BaizePath.projectRoot, platformFileSystem: PlatformFileSystem? = nil) {
        self.rootPath = rootPath
        self.platformFileSystem = platformFileSystem ?? PlatformFileSystem(rootPath: rootPath)

        // 同步确保根目录存在（使用 PlatformFileSystem 的初始化已经创建）
        baizeLogger.info("FileSystemService initialized at \(rootPath)")
    }

    /// 更改项目根目录（class 引用语义，变更即时传播）
    /// - Parameter path: 新的项目根目录绝对路径
    func setRootPath(_ path: String) {
        rootPath = path
        Task {
            await platformFileSystem.setRootPath(path)
        }
        baizeLogger.info("FileSystemService: rootPath updated to \(path)")
    }

    /// T03: 更新项目根目录 — 切换项目时调用
    /// 与 setRootPath 功能一致，提供语义更清晰的方法名
    /// - Parameter path: 新的项目根目录绝对路径
    func updateRootPath(_ path: String) {
        setRootPath(path)
    }

    // MARK: - Read Operations

    /// 读取文件内容
    /// - Parameter path: 绝对文件路径
    /// - Returns: 文件内容字符串
    func readFile(at path: String) throws -> String {
        return try runSync {
            try await self.platformFileSystem.readFile(at: path)
        }
    }

    // MARK: - Write Operations

    /// 写入文件内容（创建或覆盖）
    /// - Parameters:
    ///   - path: 绝对文件路径
    ///   - content: 要写入的内容
    func writeFile(at path: String, content: String) throws {
        try runSync {
            try await self.platformFileSystem.writeFile(at: path, content: content)
        }
    }

    /// 精确字符串替换编辑（类似 Claude Code 的 edit_file）
    /// - Parameters:
    ///   - path: 文件路径
    ///   - oldString: 要替换的原始字符串（必须精确匹配且唯一）
    ///   - newString: 替换后的新字符串
    /// - Returns: 是否成功找到并替换（true=替换成功，false=未找到匹配）
    func editFile(at path: String, oldString: String, newString: String) throws -> Bool {
        return try runSync {
            try await self.platformFileSystem.editFile(at: path, oldString: oldString, newString: newString)
        }
    }

    // MARK: - Directory Operations

    /// 列出目录内容
    /// - Parameter path: 目录路径（默认为项目根目录）
    /// - Returns: FileItem 数组
    func listDirectory(at path: String? = nil) throws -> [FileItem] {
        let dirPath = path ?? rootPath
        return try runSync {
            try await self.platformFileSystem.listDirectory(at: dirPath)
        }
    }

    // MARK: - Search Operations

    /// Glob 模式搜索文件名
    /// - Parameters:
    ///   - pattern: glob 模式
    ///   - path: 搜索起始目录（默认项目根目录）
    /// - Returns: 匹配的文件路径列表
    func searchFiles(pattern: String, in path: String? = nil) throws -> [String] {
        let searchPath = path ?? rootPath
        return try runSync {
            try await self.platformFileSystem.searchFiles(pattern: pattern, in: searchPath)
        }
    }

    /// Grep 搜索文件内容
    /// - Parameters:
    ///   - pattern: 搜索关键词
    ///   - path: 搜索起始目录
    /// - Returns: SearchResult 数组
    func searchContent(pattern: String, in path: String? = nil) throws -> [SearchResult] {
        let searchPath = path ?? rootPath
        return try runSync {
            try await self.platformFileSystem.searchContent(pattern: pattern, in: searchPath)
        }
    }

    // MARK: - Create/Delete Operations

    /// 创建目录
    func createDirectory(at path: String) throws {
        try runSync {
            try await self.platformFileSystem.createDirectory(at: path)
        }
        baizeLogger.info("Create directory: \(path)")
    }

    /// 删除文件或目录
    func deleteItem(at path: String) throws {
        // 安全检查：不允许删除项目根目录（PlatformFileSystem 中也做了检查）
        if path == rootPath || path == BaizePath.projectRoot {
            throw BaizeError.permissionDenied("不允许删除项目根目录")
        }
        try runSync {
            try await self.platformFileSystem.deleteItem(at: path)
        }
        baizeLogger.info("Delete item: \(path.fileName)")
    }

    /// 检查文件/目录是否存在
    func itemExists(at path: String) -> Bool {
        // itemExists 不涉及写操作，直接同步调用 FileManager
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Private Helpers

    /// 线程安全的结果容器 — 替代 captured var，满足 Swift 6 严格并发检查
    private final class LockedBox<T>: @unchecked Sendable {
        private var _value: T?
        private let lock = NSLock()

        func get() -> T? {
            lock.lock(); defer { lock.unlock() }
            return _value
        }

        func set(_ value: T) {
            lock.lock(); defer { lock.unlock() }
            _value = value
        }
    }

    /// 在同步上下文中等待 actor 的 async 调用
    /// 使用 Task.detached 在全局并发队列执行，避免阻塞当前 actor/主线程
    private func runSync<T>(_ operation: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Result<T, Error>>()

        Task.detached {
            do {
                let value = try await operation()
                box.set(.success(value))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()

        guard let finalResult = box.get() else {
            throw BaizeError.fileSystemError("同步等待文件系统操作未完成")
        }

        return try finalResult.get()
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
