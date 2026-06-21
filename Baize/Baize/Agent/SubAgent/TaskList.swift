import Foundation

/// 共享任务列表 — Sub-agent 团队的任务 CRUD
///
/// T04 完整实现，替换 T01 在 AppState.swift 的占位空 actor
/// 线程安全（actor 天然），所有方法都是 actor-isolated
/// TaskItem 定义在 Agent/SubAgent/TaskItem.swift
actor TaskList {

    // MARK: - Properties

    /// 任务字典 — id → TaskItem
    private var tasks: [UUID: TaskItem] = [:]

    // MARK: - Initialization

    init() {
        agentLogger.info("TaskList initialized")
    }

    // MARK: - CRUD

    /// 创建新任务
    /// - Parameters:
    ///   - subject: 任务标题
    ///   - description: 任务描述
    ///   - owner: 任务所有者（agent 名称，可选）
    /// - Returns: 创建的 TaskItem
    @discardableResult
    func create(subject: String, description: String, owner: String? = nil) -> TaskItem {
        let task = TaskItem(
            subject: subject,
            description: description,
            owner: owner
        )
        tasks[task.id] = task
        agentLogger.info("TaskList: created task '\(subject)' (id=\(task.id))")
        return task
    }

    /// 更新任务
    /// - Parameters:
    ///   - taskId: 任务 ID
    ///   - status: 新状态（可选）
    ///   - owner: 新所有者（可选）
    /// - Returns: 更新后的 TaskItem（如果任务存在）
    @discardableResult
    func update(taskId: UUID, status: TaskStatus? = nil, owner: String? = nil) -> TaskItem? {
        guard var task = tasks[taskId] else {
            agentLogger.warning("TaskList: task not found (id=\(taskId))")
            return nil
        }

        if let status = status {
            task.status = status
        }
        if let owner = owner {
            task.owner = owner
        }

        tasks[taskId] = task
        agentLogger.info("TaskList: updated task '\(task.subject)' → status=\(task.status.rawValue)")
        return task
    }

    /// 获取所有任务（排除已删除）
    /// - Returns: 任务数组（按创建时间排序）
    func list() -> [TaskItem] {
        tasks.values
            .filter { $0.status != .deleted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 获取指定任务
    /// - Parameter taskId: 任务 ID
    /// - Returns: TaskItem（如果存在且未删除）
    func get(taskId: UUID) -> TaskItem? {
        guard let task = tasks[taskId], task.status != .deleted else {
            return nil
        }
        return task
    }

    /// 删除任务（软删除）
    /// - Parameter taskId: 任务 ID
    func delete(taskId: UUID) {
        if var task = tasks[taskId] {
            task.status = .deleted
            tasks[taskId] = task
            agentLogger.info("TaskList: deleted task '\(task.subject)' (id=\(taskId))")
        }
    }

    /// 按 UUID 字符串获取任务（便捷方法，供工具层调用）
    /// - Parameter taskIdString: 任务 ID 的字符串形式
    /// - Returns: TaskItem（如果存在且未删除）
    func get(taskIdString: String) -> TaskItem? {
        guard let uuid = UUID(uuidString: taskIdString) else { return nil }
        return get(taskId: uuid)
    }

    /// 按 UUID 字符串更新任务（便捷方法，供工具层调用）
    /// - Parameters:
    ///   - taskIdString: 任务 ID 的字符串形式
    ///   - status: 新状态（可选）
    ///   - owner: 新所有者（可选）
    /// - Returns: 更新后的 TaskItem（如果任务存在）
    @discardableResult
    func update(taskIdString: String, status: TaskStatus? = nil, owner: String? = nil) -> TaskItem? {
        guard let uuid = UUID(uuidString: taskIdString) else { return nil }
        return update(taskId: uuid, status: status, owner: owner)
    }
}
