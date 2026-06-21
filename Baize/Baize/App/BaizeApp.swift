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

    /// Node.js Runtime Engine (nodejs-mobile 进程内运行时)
    private let nodeRuntimeEngine: NodeRuntimeEngine

    /// Python Runtime Engine (CPython 3.13 嵌入模式)
    private let pythonRuntimeEngine: PythonRuntimeEngine

    /// Git Service (actor，封装 libgit2 C API)
    private let gitService: GitService

    /// T03: Project Registry — 项目注册表（actor，持久化项目列表）
    private let projectRegistry: ProjectRegistry

    /// T03: Usage Tracker — 用量统计（actor，T04 深度集成）
    private let usageTracker: UsageTracker

    /// T04: Terminal History Store — 终端命令历史持久化（actor，按项目隔离）
    private let terminalHistoryStore: TerminalHistoryStore

    // MARK: - Initialization

    init() {
        let keychain = KeychainService()

        // 检测可用的工作目录：优先 TrollStore no-sandbox 路径，失败则用沙箱 Documents
        let workingRoot = BaizeApp.resolveWorkingDirectory()

        let fsService = FileSystemService(rootPath: workingRoot)
        let nodeEngine = NodeRuntimeEngine()
        // 不在 init 同步启动 — App 启动时 framework 还在加载，两个重型运行时
        // 同时初始化会导致 V8 引擎 EXC_BAD_ACCESS 崩溃。
        // 延迟到 App 完全启动后串行启动（见 body.onAppear）
        let nodeStrategy = NodeMobileStrategy(engine: nodeEngine)

        let pythonEngine = PythonRuntimeEngine()
        let pythonStrategy = PythonEmbeddingStrategy(engine: pythonEngine)

        // Git Service — 封装 libgit2，传入工作目录和 Keychain 服务
        let gitSvc = GitService(repositoryPath: workingRoot, keychainService: keychain)

        let runtime = RuntimeExecutor(nodeStrategy: nodeStrategy, pythonStrategy: pythonStrategy)
        let permission = PermissionEngine(mode: BaizePermission.defaultMode)
        let projectCtx = ProjectContext(rootPath: workingRoot, fileSystemService: fsService)
        let api = APIGateway(keychainService: keychain)
        // P0-2: ContextManager 注入 apiGateway，用于调 LLM 生成上下文摘要
        let contextMgr = ContextManager(projectContext: projectCtx, apiGateway: api)
        let conversation = ConversationStore()
        let registry = ToolRegistry(fileSystemService: fsService, runtimeExecutor: runtime, nodeEngine: nodeEngine, pythonEngine: pythonEngine)

        // T03: 创建 ProjectRegistry + UsageTracker
        let projectRegistry = ProjectRegistry(storePath: BaizePath.projectsRegistry)
        let usageTracker = UsageTracker(storeDir: BaizePath.usageData)
        // T04: 创建 TerminalHistoryStore（终端命令历史，按项目隔离）
        let terminalHistoryStore = TerminalHistoryStore(storeDir: BaizePath.terminalHistory)

        self.keychainService = keychain
        self.apiGateway = api
        self.toolRegistry = registry
        self.permissionEngine = permission
        self.projectContext = projectCtx
        self.contextManager = contextMgr
        self.conversationStore = conversation
        self.fileSystemService = fsService
        self.runtimeExecutor = runtime
        self.nodeRuntimeEngine = nodeEngine
        self.pythonRuntimeEngine = pythonEngine
        self.gitService = gitSvc
        self.projectRegistry = projectRegistry
        self.usageTracker = usageTracker
        self.terminalHistoryStore = terminalHistoryStore

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
            state.pythonRuntimeEngine = pythonEngine
            state.currentProjectPath = workingRoot

            // 终端 UI：创建 TerminalViewModel 并注入 AppState
            // TerminalViewModel 是 @MainActor，init() 在主线程执行，安全
            // 生命周期：App 启动创建一次，App 生命周期内不销毁
            state.terminalViewModel = TerminalViewModel(
                runtimeExecutor: runtime,
                initialWorkingDir: workingRoot,
                terminalHistoryStore: terminalHistoryStore
            )

            // Git 集成：创建 GitViewModel 并注入 AppState
            let gitVM = GitViewModel(gitService: gitSvc)
            state.gitService = gitSvc
            state.gitViewModel = gitVM

            // T03: 注入 ProjectRegistry + UsageTracker
            state.projectRegistry = projectRegistry
            state.usageTracker = usageTracker

            // Phase 2C: 恢复上次 Provider/Model 选择
            state.restoreProviderSelection()
            state.restoreCustomConfig()
            Task {
                // T04: 注入 UsageTracker 到 APIGateway（非侵入式拦截 usage 记录用量）
                await api.setUsageTracker(usageTracker)
                do {
                    try await api.setActiveProvider(providerId: state.activeProvider.providerId, model: state.activeModel)
                } catch {
                    baizeLogger.error("Failed to restore provider selection: \(error.localizedDescription)")
                }
            }

            return state
        }())
    }

    /// 检测可用的工作目录
    /// 优先尝试 TrollStore no-sandbox 路径，失败则使用 App 沙箱 Documents 目录
    /// Bug 3 fix: 同时确保终端历史目录存在；Bug 5 fix: 确保所有内部子目录存在
    private static func resolveWorkingDirectory() -> String {
        let fm = FileManager.default
        let trollStorePath = BaizePath.projectRoot

        // 尝试创建 TrollStore 路径
        do {
            try fm.ensureDirectoryExists(atPath: trollStorePath)
            try fm.ensureDirectoryExists(atPath: BaizePath.internalData)
            try fm.ensureDirectoryExists(atPath: BaizePath.conversations)
            // Bug 3 fix: 确保终端历史目录存在
            try fm.ensureDirectoryExists(atPath: BaizePath.terminalHistory)
            // Bug 5 fix: 确保用量数据目录存在
            try fm.ensureDirectoryExists(atPath: BaizePath.usageData)
            baizeLogger.info("Using TrollStore no-sandbox path: \(trollStorePath)")

            // Bug 3 fix: 恢复上次打开的项目路径
            // 如果 UserDefaults 中保存了上次的项目路径且该目录仍存在，则使用它
            // 否则使用默认的 projectRoot
            if let lastPath = UserDefaults.standard.string(forKey: BaizeGit.lastProjectPathUDKey),
               !lastPath.isEmpty,
               fm.fileExists(atPath: lastPath) {
                baizeLogger.info("Restoring last project path: \(lastPath)")
                return lastPath
            }
            return trollStorePath
        } catch {
            baizeLogger.warning("TrollStore path not accessible: \(trollStorePath) — \(error.localizedDescription)")
        }

        // Fallback: 使用 App 沙箱 Documents 目录
        let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.path
        let sandboxRoot = (docsDir as NSString).appendingPathComponent("Baize")
        let sandboxInternal = (sandboxRoot as NSString).appendingPathComponent(".baize")
        let sandboxConv = (sandboxInternal as NSString).appendingPathComponent("conversations")
        let sandboxTermHistory = (sandboxInternal as NSString).appendingPathComponent("terminal_history")
        let sandboxUsage = (sandboxInternal as NSString).appendingPathComponent("usage")

        try? fm.ensureDirectoryExists(atPath: sandboxRoot)
        try? fm.ensureDirectoryExists(atPath: sandboxInternal)
        try? fm.ensureDirectoryExists(atPath: sandboxConv)
        try? fm.ensureDirectoryExists(atPath: sandboxTermHistory)
        try? fm.ensureDirectoryExists(atPath: sandboxUsage)

        baizeLogger.info("Using sandbox fallback path: \(sandboxRoot)")
        return sandboxRoot + "/"
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

                    // T03: 加载项目注册表 + 注册当前项目
                    Task {
                        await appState.projectRegistry?.load()
                        await appState.registerCurrentProject()
                        baizeLogger.info("ProjectRegistry loaded + current project registered")
                    }

                    // 延迟启动运行时引擎 — App 完全启动后再初始化重型 C 运行时
                    // 串行启动：先 Node，等 2 秒后再 Python，避免两个 V8/CPython
                    // 同时初始化导致 EXC_BAD_ACCESS 崩溃
                    Task {
                        // 等 App 完全启动（framework 加载完成 + UI 就绪）
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s

                        if BaizeRuntime.pythonIsolationTest {
                            // P3 隔离测试模式：跳过 Node.js，直接启动 Python
                            // 用于真机验证 Python 单独是否崩溃（排除 V8 干扰）
                            baizeLogger.info("Python isolation test mode — skipping Node.js startup")
                        } else {
                            baizeLogger.info("Starting Node.js engine (deferred)...")
                            nodeRuntimeEngine.start()

                            // Node 引擎启动后再等 2 秒启动 Python，避免资源竞争
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                        }

                        baizeLogger.info("Starting Python engine (deferred)...")
                        pythonRuntimeEngine.start()
                    }
                }
        }
    }
}