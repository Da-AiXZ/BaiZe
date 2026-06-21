import Foundation

/// 团队协调器 — 管理 Sub-agent 团队的创建和通信
///
/// T04 完整实现，替换 T01 在 AppState.swift 的占位空 actor
/// 管理子 AgentLoop 实例，支持 spawn/sendMessage/listAgents
/// 子 agent 共享 ToolRegistry（同进程），但独立 session + 独立 PermissionEngine
actor TeamCoordinator {

    // MARK: - Properties

    /// 已注册的子 agent 字典 — name → AgentLoop
    private var agents: [String: AgentLoop] = [:]

    /// 共享任务列表引用
    private let taskList: TaskList

    /// 团队名称
    private var teamName: String = ""

    /// 团队描述
    private var teamDescription: String = ""

    /// 消息收件箱 — agentName → [IncomingMessage]
    private var inboxes: [String: [IncomingMessage]] = [:]

    // MARK: - Initialization

    init(taskList: TaskList) {
        self.taskList = taskList
        agentLogger.info("TeamCoordinator initialized")
    }

    // MARK: - Team Management

    /// 创建团队
    /// - Parameters:
    ///   - name: 团队名称
    ///   - description: 团队描述
    func createTeam(name: String, description: String) {
        self.teamName = name
        self.teamDescription = description
        agentLogger.info("TeamCoordinator: team created '\(name)' — \(description)")
    }

    /// Spawn 子 agent — 创建新 AgentLoop 实例
    ///
    /// 子 agent 共享主 agent 的 ToolRegistry（同进程并发），
    /// 但拥有独立的 ConversationSession 和 PermissionEngine（默认 .plan 模式，仅只读工具）。
    ///
    /// - Parameters:
    ///   - name: 子 agent 名称（唯一标识）
    ///   - subagentType: 子 agent 类型（如 "general-purpose", "researcher" 等）
    ///   - teamName: 团队名称（可选）
    ///   - agentLoopFactory: 创建 AgentLoop 的工厂闭包
    /// - Returns: 创建的 AgentLoop 实例
    @discardableResult
    func spawnTeammate(
        name: String,
        subagentType: String = "general-purpose",
        teamName: String? = nil,
        agentLoopFactory: () -> AgentLoop
    ) -> AgentLoop {
        let loop = agentLoopFactory()
        agents[name] = loop
        inboxes[name] = []
        agentLogger.info("TeamCoordinator: spawned teammate '\(name)' (type=\(subagentType))")
        return loop
    }

    /// 获取已注册的子 agent 名称列表
    /// - Returns: agent 名称数组
    func listAgents() -> [String] {
        Array(agents.keys).sorted()
    }

    /// 获取指定子 agent 的 AgentLoop
    /// - Parameter name: agent 名称
    /// - Returns: AgentLoop 实例（如果存在）
    func getAgent(name: String) -> AgentLoop? {
        agents[name]
    }

    // MARK: - Messaging

    /// 发送消息 — 从一个 agent 发送到另一个 agent
    /// - Parameters:
    ///   - from: 发送方 agent 名称
    ///   - to: 接收方 agent 名称
    ///   - content: 消息内容
    func sendMessage(from: String, to: String, content: String) {
        let message = IncomingMessage(from: from, content: content, timestamp: Date())
        inboxes[to, default: []].append(message)
        agentLogger.info("TeamCoordinator: message from '\(from)' to '\(to)': \(content.prefix(50))")
    }

    /// 读取指定 agent 的收件箱消息
    /// - Parameter name: agent 名称
    /// - Returns: 未读消息列表（读取后清空）
    func readMessages(name: String) -> [IncomingMessage] {
        let messages = inboxes[name] ?? []
        inboxes[name] = []
        return messages
    }

    /// 检查指定 agent 是否有未读消息
    /// - Parameter name: agent 名称
    /// - Returns: 是否有未读消息
    func hasMessages(name: String) -> Bool {
        !(inboxes[name]?.isEmpty ?? true)
    }

    // MARK: - Task List Access

    /// 获取共享任务列表
    /// - Returns: TaskList 引用
    func getTaskList() -> TaskList {
        taskList
    }

    // MARK: - Shutdown

    /// 关闭所有子 agent
    func shutdownAll() async {
        for (name, loop) in agents {
            await loop.stop()
            agentLogger.info("TeamCoordinator: stopped agent '\(name)'")
        }
        agents.removeAll()
        inboxes.removeAll()
    }
}

// MARK: - Incoming Message

/// agent 间消息 — 从其他 agent 收到的消息
struct IncomingMessage: Sendable {
    /// 发送方 agent 名称
    let from: String
    /// 消息内容
    let content: String
    /// 时间戳
    let timestamp: Date
}
