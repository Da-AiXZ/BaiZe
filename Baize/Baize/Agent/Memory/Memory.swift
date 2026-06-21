import Foundation

// MARK: - Memory Scope

/// 记忆作用域 — 标识记忆的可见范围
/// 三级作用域：user（跨所有项目）→ project（单项目）→ team（多 agent 共享）
enum MemoryScope: String, Sendable, Codable {
    /// 用户级 — 跨所有项目的用户偏好/决策记忆
    case user
    /// 项目级 — 单项目特定的记忆（按项目路径隔离存储）
    case project
    /// 团队级 — 多 agent 共享记忆（Sub-agent 团队协作）
    case team
}

// MARK: - Memory Type

/// 记忆类型 — 分类记忆内容
enum MemoryType: String, Sendable, Codable {
    /// 用户偏好（如"偏好使用 Swift 5.9 语法"）
    case preference
    /// 技术决策（如"选择 FastAPI 而非 Flask"）
    case decision
    /// 待办事项（如"需要修复 login 页面的 bug"）
    case todo
    /// 事实知识（如"项目使用 SQLite 数据库"）
    case fact
    /// 工作日志（如"已完成 user 模块的单元测试"）
    case workLog
}

// MARK: - Memory Model

/// 记忆数据模型 — 一条持久化的记忆条目
/// 存储为 JSONL 格式（每行一条 JSON），按 scope 分文件存储
/// 检索时加载所有 scope 的记忆，关键词匹配 + 时间衰减打分
struct Memory: Sendable, Codable {
    /// 唯一标识
    let id: UUID

    /// 作用域 — user/project/team
    let scope: MemoryScope

    /// 记忆内容文本
    let content: String

    /// 记忆类型 — preference/decision/todo/fact/workLog
    let type: MemoryType

    /// 创建时间
    let createdAt: Date

    /// 最后访问时间（用于时间衰减打分）
    var lastAccessedAt: Date

    /// 访问次数（命中检索时递增）
    var accessCount: Int

    /// 关键词列表 — 用于检索匹配
    let keywords: [String]

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        content: String,
        type: MemoryType,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        accessCount: Int = 0,
        keywords: [String] = []
    ) {
        self.id = id
        self.scope = scope
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.keywords = keywords
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, scope, content, type
        case createdAt, lastAccessedAt, accessCount, keywords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        scope = try container.decode(MemoryScope.self, forKey: .scope)
        content = try container.decode(String.self, forKey: .content)
        type = try container.decode(MemoryType.self, forKey: .type)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastAccessedAt = try container.decode(Date.self, forKey: .lastAccessedAt)
        accessCount = try container.decode(Int.self, forKey: .accessCount)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}
