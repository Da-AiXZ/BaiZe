import Foundation

// MARK: - SubAgent Context

/// 子 Agent 隔离上下文
///
/// 每个子 Agent 拥有独立的：
/// - PlatformFileSystem 实例（写操作策略独立）
/// - PermissionEngine 实例（权限决策独立，不继承父 Agent 的 bypass/plan 状态）
/// - ConversationSession 实例（对话历史独立）
/// - FileSystemService 包装（兼容旧接口）
///
/// 但共享：
/// - RuntimeExecutor（全局串行执行，避免 ios_system 进程级状态污染）
/// - ToolRegistry（工具定义只读，安全共享）
/// - APIGateway、GitService 等无状态服务
///
/// 参考 Claude Code forkedAgent：子 agent 独立上下文，父 agent 只收集最终结果。
struct SubAgentContext: Sendable {

    // MARK: - Properties

    /// 项目根目录（与父 Agent 相同，不跨项目隔离）
    let projectPath: String

    /// 独立的平台文件系统
    let platformFileSystem: PlatformFileSystem

    /// 兼容包装层（供旧 AgentLoop / ContextManager 使用）
    let fileSystemService: FileSystemService

    /// 独立的权限引擎
    let permissionEngine: PermissionEngine

    /// 独立的对话会话
    let conversationSession: ConversationSession

    // MARK: - Initialization

    /// 从父 Agent 的 ToolExecutionContext 创建子 Agent 上下文
    /// - Parameters:
    ///   - projectPath: 项目根目录
    ///   - parentPlatformFileSystem: 父 Agent 的 PlatformFileSystem（用于继承当前策略）
    ///   - toolRegistry: 工具注册表（注入到 PermissionEngine）
    init(
        projectPath: String,
        parentPlatformFileSystem: PlatformFileSystem,
        toolRegistry: ToolRegistry? = nil
    ) async {
        self.projectPath = projectPath

        // 继承父 Agent 当前的文件系统策略类型，但创建独立实例
        let parentStrategy = await parentPlatformFileSystem.currentStrategy()
        self.platformFileSystem = PlatformFileSystem(
            rootPath: projectPath,
            strategyType: parentStrategy
        )

        // 基于独立 PlatformFileSystem 创建 FileSystemService
        self.fileSystemService = FileSystemService(
            rootPath: projectPath,
            platformFileSystem: self.platformFileSystem
        )

        // 独立 PermissionEngine，默认模式，不继承父 Agent 的 bypass/plan/dontAsk
        self.permissionEngine = PermissionEngine(mode: .default)
        if let registry = toolRegistry {
            await self.permissionEngine.setToolRegistry(registry)
        }

        // 独立会话
        self.conversationSession = ConversationSession(projectPath: projectPath)

        agentLogger.info("SubAgentContext created at \(projectPath) with strategy \(parentStrategy.rawValue)")
    }

    /// 创建子 Agent 的 ContextManager（不注入 memoryStore，避免记忆污染）
    func makeContextManager(apiGateway: APIGateway) -> ContextManager {
        ContextManager(
            projectContext: ProjectContext(
                rootPath: projectPath,
                fileSystemService: fileSystemService
            ),
            apiGateway: apiGateway,
            memoryStore: nil
        )
    }
}
