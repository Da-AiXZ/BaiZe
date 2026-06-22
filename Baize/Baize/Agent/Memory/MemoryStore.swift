import Foundation

/// 记忆存储 — 会话记忆的持久化和检索
///
/// 存储格式：JSONL（每行一条 JSON），按 scope 分文件存储
/// - user scope → BaizePath.userMemoryDir/memories.jsonl
/// - project scope → BaizePath.projectMemoryDir/memories.jsonl
/// - team scope → BaizePath.teamMemoryDir/memories.jsonl
///
/// 检索算法（简单版）：
/// score = keywordMatchCount * 1.0 + recencyScore * 0.5
/// recencyScore = 1.0 / (1 + daysSinceLastAccess)
/// 加载所有 scope 的记忆，按 score 降序取 top limit
actor MemoryStore {

    // MARK: - Properties

    /// 记忆存储根目录
    private let baseDir: String

    /// JSON 编码器（配置日期格式）
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// JSON 解码器（配置日期格式）
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    init(baseDir: String = BaizePath.memoryDir) {
        self.baseDir = baseDir
        ensureDirectoriesExist()
        memoryLogger.info("MemoryStore initialized with baseDir: \(baseDir)")
    }

    // MARK: - Append

    /// 追加一条记忆到对应 scope 的 memories.jsonl
    /// - Parameters:
    ///   - scope: 记忆作用域
    ///   - content: 记忆内容文本
    ///   - type: 记忆类型
    ///   - keywords: 关键词列表（用于检索匹配）
    func appendMemory(
        scope: MemoryScope,
        content: String,
        type: MemoryType,
        keywords: [String] = []
    ) async {
        let memory = Memory(
            scope: scope,
            content: content,
            type: type,
            keywords: keywords
        )

        let filePath = memoryFilePath(scope: scope)

        do {
            let jsonLine = encodeMemory(memory)
            let lineToWrite = jsonLine + "\n"

            let fm = FileManager.default
            if fm.fileExists(atPath: filePath) {
                // 追加到现有文件
                if let handle = FileHandle(forWritingAtPath: filePath) {
                    handle.seekToEndOfFile()
                    handle.write(lineToWrite.data(using: .utf8)!)
                    handle.closeFile()
                }
            } else {
                // 创建新文件
                try lineToWrite.write(toFile: filePath, atomically: true, encoding: .utf8)
            }

            memoryLogger.info("MemoryStore: appended \(type.rawValue) memory to \(scope.rawValue) scope")
        } catch {
            memoryLogger.error("MemoryStore: failed to append memory: \(error.localizedDescription)")
        }
    }

    // MARK: - Retrieve

    /// 查找相关记忆 — 加载所有 scope 的记忆，关键词匹配 + 时间衰减打分
    /// - Parameters:
    ///   - query: 查询文本（用户输入或会话内容）
    ///   - limit: 返回的最大记忆条数
    /// - Returns: 按相关度降序排列的记忆列表
    func findRelevantMemories(query: String, limit: Int = BaizeToken.memoryInjectionLimit) async -> [Memory] {
        // 1. 加载所有 scope 的记忆
        var allMemories: [Memory] = []
        for scope in [MemoryScope.user, .project, .team] {
            allMemories.append(contentsOf: loadMemories(scope: scope))
        }

        guard !allMemories.isEmpty else {
            return []
        }

        // 2. 打分
        let lowercasedQuery = query.lowercased()
        let queryWords = lowercasedQuery.split(separator: " ").map(String.init)

        let scored = allMemories.map { memory -> (memory: Memory, score: Double) in
            let score = calculateScore(memory: memory, query: lowercasedQuery, queryWords: queryWords)
            return (memory, score)
        }

        // 3. 过滤零分 + 降序排序 + 取 top limit
        let relevant = scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.memory }

        return Array(relevant)
    }

    /// 获取指定 scope 的所有记忆
    /// - Parameter scope: 记忆作用域
    /// - Returns: 该 scope 下所有记忆列表
    func getMemories(scope: MemoryScope) async -> [Memory] {
        loadMemories(scope: scope)
    }

    // MARK: - Scoring

    /// 计算记忆的相关度分数
    /// score = keywordMatchCount * 1.0 + recencyScore * 0.5
    /// - recencyScore = 1.0 / (1 + daysSinceLastAccess)
    /// - keywordMatchCount: query 包含记忆 keywords 的数量
    private func calculateScore(memory: Memory, query: String, queryWords: [String]) -> Double {
        // 关键词匹配分数
        var keywordMatchCount: Double = 0
        for keyword in memory.keywords {
            if query.contains(keyword.lowercased()) {
                keywordMatchCount += 1.0
            }
        }

        // 记忆内容自身的关键词也参与匹配
        let memoryContentLower = memory.content.lowercased()
        for queryWord in queryWords {
            if memoryContentLower.contains(queryWord) {
                keywordMatchCount += 0.5
            }
        }

        // 时间衰减分数
        let daysSinceLastAccess = max(0, Date().timeIntervalSince(memory.lastAccessedAt) / 86400)
        let recencyScore = 1.0 / (1.0 + daysSinceLastAccess)

        return keywordMatchCount * 1.0 + recencyScore * 0.5
    }

    // MARK: - File I/O

    /// 加载指定 scope 的所有记忆
    private func loadMemories(scope: MemoryScope) -> [Memory] {
        let filePath = memoryFilePath(scope: scope)
        let fm = FileManager.default

        guard fm.fileExists(atPath: filePath) else {
            return []
        }

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            memoryLogger.warning("MemoryStore: cannot read \(filePath)")
            return []
        }

        var memories: [Memory] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            if let memory = decodeMemory(String(line)) {
                memories.append(memory)
            }
        }

        return memories
    }

    /// 获取指定 scope 的记忆文件路径
    private func memoryFilePath(scope: MemoryScope) -> String {
        let dir: String
        switch scope {
        case .user: dir = BaizePath.userMemoryDir
        case .project: dir = BaizePath.projectMemoryDir
        case .team: dir = BaizePath.teamMemoryDir
        }
        return (dir as NSString).appendingPathComponent("memories.jsonl")
    }

    /// 编码 Memory 为 JSON 字符串
    private func encodeMemory(_ memory: Memory) -> String {
        do {
            let data = try encoder.encode(memory)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            memoryLogger.error("MemoryStore: encode failed: \(error.localizedDescription)")
            return "{}"
        }
    }

    /// 解码 JSON 字符串为 Memory
    private func decodeMemory(_ json: String) -> Memory? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(Memory.self, from: data)
    }

    /// 确保记忆目录存在
    private func ensureDirectoriesExist() {
        let fm = FileManager.default
        let dirs = [baseDir, BaizePath.userMemoryDir, BaizePath.projectMemoryDir, BaizePath.teamMemoryDir]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}
