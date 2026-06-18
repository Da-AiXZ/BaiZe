import SwiftUI

/// 白泽 iOS 本地编程智能体 — SwiftUI 应用入口
/// T05: 完整依赖注入 — 创建所有服务实例并注入到视图层级
/// 通过 TrollStore 安装，拥有 no-sandbox + platform-application 特权
@main
struct BaizeApp: App {
    @StateObject private var appState = AppState()

    // MARK: - Dependency Injection (T05)

    /// Keychain 安全存储服务（init 中赋值，去掉默认值避免 let 双重初始化）
    private let keychainService: KeychainService

    /// API Gateway（actor）
    private let apiGateway: APIGateway

    /// Tool Registry（actor）
    private let toolRegistry: ToolRegistry

    /// Permission Engine（actor，W4 fix: 确保权限状态共享 + 线程安全）
    private let permissionEngine: PermissionEngine

    /// Project Context（class 引用类型，load() 变更即时持久化）
    private let projectContext: ProjectContext

    /// Context Manager
    private let contextManager: ContextManager

    /// Conversation Store（actor，W1 fix: 防止并发数据竞争）
    private let conversationStore: ConversationStore

    /// File System Service
    private let fileSystemService: FileSystemService

    /// Runtime Executor
    private let runtimeExecutor: RuntimeExecutor

    // MARK: - Initialization

    init() {
        let keychain = KeychainService()
        let fsService = FileSystemService(rootPath: BaizePath.projectRoot)
        let runtime = RuntimeExecutor()
        let permission = PermissionEngine(mode: BaizePermission.defaultMode)
        let projectCtx = ProjectContext(rootPath: BaizePath.projectRoot, fileSystemService: fsService)
        let contextMgr = ContextManager(projectContext: projectCtx)
        let conversation = ConversationStore()
        let api = APIGateway(keychainService: keychain)
        let registry = ToolRegistry(fileSystemService: fsService, runtimeExecutor: runtime)

        self.keychainService = keychain
        self.apiGateway = api
        self.toolRegistry = registry
        self.permissionEngine = permission
        self.projectContext = projectCtx
        self.contextManager = contextMgr
        self.conversationStore = conversation
        self.fileSystemService = fsService
        self.runtimeExecutor = runtime

        // W22 fix: 将所有服务实例注入 AppState，供 ChatView 等视图共享
        _appState = StateObject(wrappedValue: {
            let state = AppState()
            state.keychainService = keychain
            state.apiGateway = api
            state.toolRegistry = registry
            state.permissionEngine = permission
            state.projectContext = projectCtx
            state.contextManager = contextMgr
            state.conversationStore = conversation
            state.fileSystemService = fsService
            state.runtimeExecutor = runtime

            // Phase 2C: 恢复上次 Provider/Model 选择
            state.restoreProviderSelection()
            state.restoreCustomConfig()
            Task {
                do {
                    try await api.setActiveProvider(providerId: state.activeProvider.providerId, model: state.activeModel)
                } catch {
                    baizeLogger.error("Failed to restore provider selection: \(error.localizedDescription)")
                }
            }

            return state
        }())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .preferredColorScheme(.dark)
                .environmentObject(appState)
                .onAppear {
                    // 启动时检查 API Key 配置状态
                    appState.updateAPIStatus(isConfigured: keychainService.hasAnyAPIKey())

                    // 异步加载项目上下文
                    Task {
                        try await projectContext.load()
                        baizeLogger.info("Project context loaded on startup")
                    }
                }
        }
    }
}