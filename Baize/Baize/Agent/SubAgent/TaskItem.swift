import Foundation

// MARK: - Task Status

/// 任务状态 — Sub-agent 团队共享任务列表的状态枚举
/// 替换 AgentEvent.swift 中的 T01 占位 TaskItem 的 String status 字段
enum TaskStatus: String, Sendable, Codable {
    /// 待处理
    case pending
    /// 进行中
    case inProgress
    /// 已完成
    case completed
    /// 已删除（软删除）
    case deleted
}

// MARK: - Task Item

/// 任务数据模型 — Sub-agent 团队共享任务列表的条目
/// T04 完整版：替换 AgentEvent.swift 中的 T01 占位 TaskItem
/// 新增：UUID id / TaskStatus 枚举 / owner / blocks / blockedBy / createdAt
struct TaskItem: Sendable, Codable {
    /// 唯一标识
    let id: UUID

    /// 任务标题
    var subject: String

    /// 任务描述
    var description: String

    /// 任务状态
    var status: TaskStatus

    /// 任务所有者（agent 名称，nil 表示未分配）
    var owner: String?

    /// 此任务阻塞的其他任务 ID 列表
    var blocks: [UUID]

    /// 阻止此任务的其他任务 ID 列表
    var blockedBy: [UUID]

    /// 创建时间
    let createdAt: Date

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        subject: String,
        description: String,
        status: TaskStatus = .pending,
        owner: String? = nil,
        blocks: [UUID] = [],
        blockedBy: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subject = subject
        self.description = description
        self.status = status
        self.owner = owner
        self.blocks = blocks
        self.blockedBy = blockedBy
        self.createdAt = createdAt
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, subject, description, status, owner, blocks, blockedBy, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        description = try container.decode(String.self, forKey: .description)
        // 兼容旧的 String status（T01 占位用 String，T04 用枚举）
        if let statusEnum = try? container.decode(TaskStatus.self, forKey: .status) {
            status = statusEnum
        } else if let statusString = try? container.decode(String.self, forKey: .status) {
            status = TaskStatus(rawValue: statusString) ?? .pending
        } else {
            status = .pending
        }
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        blocks = try container.decodeIfPresent([UUID].self, forKey: .blocks) ?? []
        blockedBy = try container.decodeIfPresent([UUID].self, forKey: .blockedBy) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
