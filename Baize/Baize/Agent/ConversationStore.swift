import Foundation

/// 对话持久化存储 — JSON 文件存储
/// Phase 1 使用 JSON 文件（对话量小，JSON 简单）
/// Phase 2 切换为 SQLite（对话量大时性能更好）
/// 存储路径：/var/mobile/Documents/Baize/.baize/conversations/
struct ConversationStore {

    // MARK: - Properties

    /// 存储目录路径
    private let storeDirectory: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    // MARK: - Initialization

    init(storeDirectory: String = BaizePath.conversations) {
        self.storeDirectory = storeDirectory
        // 确保存储目录存在
        try? fileManager.ensureDirectoryExists(atPath: storeDirectory)
    }

    // MARK: - Public API

    /// 保存对话会话到 JSON 文件
    /// - Parameter session: 对话会话
    func save(session: ConversationSession) throws {
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
        let filePath = sessionFilePath(for: id)

        guard fileManager.fileExists(atPath: filePath) else {
            return nil
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
        guard let files = try? fileManager.contentsOfDirectory(atPath: storeDirectory) else {
            return []
        }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }
        var sessions: [ConversationSession] = []

        for fileName in jsonFiles {
            let filePath = (storeDirectory as NSString).appendingPathComponent(fileName)
            let idString = fileName.replacingOccurrences(of: ".json", with: "")
            let id = UUID(uuidString: idString)

            if let id = id {
                if let session = load(id: id) {
                    sessions.append(session)
                }
            }
        }

        // 按更新时间降序排序
        sessions.sort { $0.updatedAt > $1.updatedAt }
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

    /// 会话文件路径（UUID.json）
    private func sessionFilePath(for id: UUID) -> String {
        (storeDirectory as NSString).appendingPathComponent("\(id.uuidString).json")
    }
}