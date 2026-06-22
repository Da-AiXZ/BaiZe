import Foundation

/// 对话持久化存储 — JSON 文件存储
/// Phase 1 使用 JSON 文件（对话量小，JSON 简单）
/// Phase 2 切换为 SQLite（对话量大时性能更好）
/// 存储路径：/var/mobile/Documents/Baize/.baize/conversations/
/// W1 fix: 改为 actor 防止并发数据竞争
actor ConversationStore {

    // MARK: - Properties

    /// 存储目录路径（可能被切换到 fallback 路径）
    private var storeDirectory: String

    /// Fallback 存储目录（App 沙箱 Documents 目录下）
    private let fallbackStoreDirectory: String

    /// Fallback 路径是否为当前活跃路径
    private var isUsingFallback: Bool = false

    /// FileManager 实例
    private let fileManager = FileManager.default

    // MARK: - Initialization

    init(storeDirectory: String = BaizePath.conversations) {
        self.storeDirectory = storeDirectory

        // 计算 fallback 路径：App 沙箱 Documents/Baize/.baize/conversations/
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        let fallbackRoot = (docsDir as NSString).appendingPathComponent("Baize")
        let fallbackInternal = (fallbackRoot as NSString).appendingPathComponent(".baize")
        let fallbackConv = (fallbackInternal as NSString).appendingPathComponent("conversations")
        self.fallbackStoreDirectory = fallbackConv

        // 尝试创建主路径目录
        do {
            try fileManager.createDirectory(atPath: storeDirectory, withIntermediateDirectories: true)
            agentLogger.info("ConversationStore: primary directory created/verified: \(storeDirectory)")
        } catch {
            agentLogger.error("ConversationStore: primary directory creation failed: \(error.localizedDescription), trying fallback")
            // 主路径失败，切到 fallback
            do {
                try fileManager.createDirectory(atPath: fallbackStoreDirectory, withIntermediateDirectories: true)
                self.storeDirectory = fallbackStoreDirectory
                self.isUsingFallback = true
                agentLogger.info("ConversationStore: using fallback directory: \(fallbackConv)")
            } catch {
                agentLogger.error("ConversationStore: fallback directory creation also failed: \(error.localizedDescription)")
                // 两个路径都失败，保持原路径（save 时会再尝试）
            }
        }
    }

    // MARK: - Public API

    /// 保存对话会话到 JSON 文件
    /// - Parameter session: 对话会话
    func save(session: ConversationSession) throws {
        // 确保目录存在（不静默吞错）
        try ensureDirectoryWritable()

        let filePath = sessionFilePath(for: session.id)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            agentLogger.info("Conversation saved: \(session.id) — \(session.messages.count) messages")
        } catch {
            throw BaizeError.fileSystemError("对话保存失败: \(error.localizedDescription)")
        }
    }

    /// 加载对话会话
    /// - Parameter id: 会话 UUID
    /// - Returns: 对话会话，不存在时返回 nil
    func load(id: UUID) -> ConversationSession? {
        var filePath = sessionFilePath(for: id)

        // 主路径不存在时尝试 fallback 路径
        if !fileManager.fileExists(atPath: filePath) {
            if !isUsingFallback {
                let fallbackPath = (fallbackStoreDirectory as NSString).appendingPathComponent("\(id.uuidString).json")
                if fileManager.fileExists(atPath: fallbackPath) {
                    filePath = fallbackPath
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let session = try decoder.decode(ConversationSession.self, from: data)
            agentLogger.info("Conversation loaded: \(id)")
            return session
        } catch {
            agentLogger.error("Conversation load error: \(error.localizedDescription)")
            return nil
        }
    }

    /// 列出所有对话会话（按更新时间排序）
    /// - Returns: ConversationSession 数组
    func listSessions() -> [ConversationSession] {
        var sessions: [ConversationSession] = []

        // 从当前存储目录读取
        sessions.append(contentsOf: readSessions(from: storeDirectory))

        // 如果不在 fallback 模式，也尝试从 fallback 目录读取（合并历史数据）
        if !isUsingFallback {
            sessions.append(contentsOf: readSessions(from: fallbackStoreDirectory))
        }

        // 去重（按 session id）
        var seen = Set<UUID>()
        sessions = sessions.filter { session in
            if seen.contains(session.id) { return false }
            seen.insert(session.id)
            return true
        }

        // 按更新时间降序排序
        sessions.sort { $0.updatedAt > $1.updatedAt }
        return sessions
    }

    /// 从指定目录读取所有会话
    /// - Parameter directory: 目录路径
    /// - Returns: 该目录下的所有 ConversationSession
    private func readSessions(from directory: String) -> [ConversationSession] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return []
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }
        var sessions: [ConversationSession] = []

        for fileName in jsonFiles {
            let filePath = (directory as NSString).appendingPathComponent(fileName)
            let idString = fileName.replacingOccurrences(of: ".json", with: "")
            let id = UUID(uuidString: idString)

            if let id = id {
                // 读取文件
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let session = try decoder.decode(ConversationSession.self, from: data)
                    sessions.append(session)
                } catch {
                    agentLogger.error("Failed to load session \(idString): \(error.localizedDescription)")
                }
            }
        }

        return sessions
    }

    /// 删除对话会话
    /// - Parameter id: 会话 UUID
    func delete(id: UUID) throws {
        let filePath = sessionFilePath(for: id)

        guard fileManager.fileExists(atPath: filePath) else {
            throw BaizeError.fileSystemError("对话文件不存在: \(filePath)")
        }

        do {
            try fileManager.removeItem(atPath: filePath)
            agentLogger.info("Conversation deleted: \(id)")
        } catch {
            throw BaizeError.fileSystemError("对话删除失败: \(error.localizedDescription)")
        }
    }

    /// 根据对话内容自动生成标题
    /// - Parameter session: 对话会话
    /// - Returns: 自动生成的标题
    func generateTitle(session: ConversationSession) -> String {
        // 从第一条用户消息生成简短标题
        for message in session.messages {
            if case .user(let text) = message {
                let firstLine = text.split(separator: "\n").first ?? ""
                let title = String(firstLine.prefix(30))
                return title.isEmpty ? "新对话" : title
            }
        }
        return "新对话"
    }

    // MARK: - Private Helpers

    /// 确保存储目录可写 — 如果主路径不可用则切换到 fallback
    /// - Throws: 目录创建失败时抛出错误
    private func ensureDirectoryWritable() throws {
        // 如果已经在用 fallback，确保 fallback 目录存在
        if isUsingFallback {
            try fileManager.createDirectory(atPath: storeDirectory, withIntermediateDirectories: true)
            return
        }

        // 尝试确保主路径存在
        do {
            try fileManager.createDirectory(atPath: storeDirectory, withIntermediateDirectories: true)
        } catch {
            // 主路径失败，切到 fallback
            agentLogger.error("ConversationStore: primary path failed at save time, switching to fallback: \(error.localizedDescription)")
            try fileManager.createDirectory(atPath: fallbackStoreDirectory, withIntermediateDirectories: true)
            storeDirectory = fallbackStoreDirectory
            isUsingFallback = true
        }
    }

    /// 会话文件路径（UUID.json）
    private func sessionFilePath(for id: UUID) -> String {
        (storeDirectory as NSString).appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Session Search (T05: #15 会话全文搜索)

    /// 全文搜索 — 在 actor 内执行避免阻塞 UI
    /// 遍历当前项目的所有会话，匹配每条消息的 content computed property
    /// - Parameters:
    ///   - query: 搜索关键词（大小写不敏感，支持中文）
    ///   - projectPath: 项目路径（按此过滤会话范围）
    /// - Returns: 匹配结果数组（按 matchCount 降序排序）
    /// 性能目标：100 会话 × 50 消息 = 5000 条，< 500ms
    func search(query: String, projectPath: String) async -> [SessionSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        // 获取所有会话并按 projectPath 过滤
        let allSessions = listSessions()
        let projectSessions = allSessions.filter { $0.projectPath == projectPath }

        let lowerQuery = query.lowercased()
        var results: [SessionSearchResult] = []

        for session in projectSessions {
            var matchCount = 0
            var firstMatchSnippet: String?
            var firstMatchMessageId: String?

            for message in session.messages {
                let content = message.content
                guard !content.isEmpty else { continue }

                // 大小写不敏感匹配
                let lowerContent = content.lowercased()
                if let range = lowerContent.range(of: lowerQuery) {
                    matchCount += 1

                    // 记录第一个匹配的片段和消息 ID
                    if firstMatchSnippet == nil {
                        // 提取匹配片段：关键词前后各 30 字符
                        let matchStart = range.lowerBound
                        let matchEnd = range.upperBound

                        let snippetStart = content.index(
                            matchStart,
                            offsetBy: -30,
                            limitedBy: content.startIndex
                        ) ?? content.startIndex

                        let snippetEnd = content.index(
                            matchEnd,
                            offsetBy: 30,
                            limitedBy: content.endIndex
                        ) ?? content.endIndex

                        // 添加省略号表示截断
                        var snippet = String(content[snippetStart..<snippetEnd])
                        if snippetStart != content.startIndex {
                            snippet = "..." + snippet
                        }
                        if snippetEnd != content.endIndex {
                            snippet = snippet + "..."
                        }
                        firstMatchSnippet = snippet
                        firstMatchMessageId = message.id
                    }
                }
            }

            if matchCount > 0 {
                results.append(SessionSearchResult(
                    sessionId: session.id,
                    sessionTitle: session.title,
                    matchedSnippet: firstMatchSnippet ?? "",
                    matchCount: matchCount,
                    matchedMessageId: firstMatchMessageId ?? ""
                ))
            }
        }

        // 按 matchCount 降序排序
        results.sort { $0.matchCount > $1.matchCount }

        return results
    }
}

// MARK: - Session Search Result (T05: #15)

/// 会话搜索结果 — 单个会话的搜索匹配信息
/// 不可新增 Message enum case（铁律 #10）— 此结构体仅用于搜索结果展示
struct SessionSearchResult: Identifiable {
    /// 唯一标识（用于 SwiftUI ForEach）
    let id = UUID()
    /// 匹配的会话 ID
    let sessionId: UUID
    /// 会话标题
    let sessionTitle: String
    /// 匹配片段（关键词前后各 30 字，带省略号）
    let matchedSnippet: String
    /// 该会话中匹配的消息总数
    let matchCount: Int
    /// 第一个匹配消息的 ID（用于跳转定位）
    let matchedMessageId: String
}