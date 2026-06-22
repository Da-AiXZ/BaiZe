import SwiftUI
import Foundation

// MARK: - App Tab Enum

/// 顶层导航 Tab 枚举 — 底部 TabView 四 Tab
enum AppTab: String, CaseIterable, Hashable {
    case workspace
    case git
    case dashboard
    case settings

    var title: String {
        switch self {
        case .workspace: return "工作区"
        case .git: return "Git"
        case .dashboard: return "首页"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace: return "hammer.fill"
        case .git: return "arrow.triangle.branch"
        case .dashboard: return "house.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Focus Mode Enum

/// 焦点模式枚举 — 控制编辑器与对话面板的宽度比
enum FocusMode: String, CaseIterable, Hashable {
    case code       // 编辑器获焦（默认）
    case chat       // 对话面板获焦（Agent 运行时）
    case balanced   // 平衡（P2 预留）

    var editorRatio: CGFloat {
        switch self {
        case .code: return 0.65
        case .chat: return 0.35
        case .balanced: return 0.50
        }
    }

    var chatRatio: CGFloat { 1.0 - editorRatio }

    var label: String {
        switch self {
        case .code: return "代码"
        case .chat: return "对话"
        case .balanced: return "平衡"
        }
    }

    /// Bug 1 fix: 焦点模式图标 — 用于显眼的焦点切换控件
    var systemImage: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .chat: return "bubble.left.fill"
        case .balanced: return "square.split.2x1"
        }
    }
}

/// 白泽全局 App 状态 — ObservableObject
/// 管理 Agent 运行状态、当前项目、文件选择、API 配置状态等
/// 所有视图通过 @EnvironmentObject 或 @ObservedObject 访问
@MainActor
class AppState: ObservableObject {
    // MARK: - Project State

    /// 当前项目路径
    @Published var currentProjectPath: String = BaizePath.projectRoot

    /// 当前选中的文件路径（用于 Monaco Editor 显示）
    @Published var selectedFilePath: String?

    /// 打开的文件 Tab 列表
    @Published var openFiles: [String] = []

    // MARK: - UI Navigation State

    /// 当前选中的 Tab（工作区/首页/设置）
    @Published var selectedTab: AppTab = .workspace

    /// 当前焦点模式（代码/对话/平衡）
    @Published var focusMode: FocusMode = .code

    // MARK: - Agent State

    /// Agent Loop 是否正在运行
    @Published var isAgentRunning: Bool = false

    /// 当前活跃会话 ID
    @Published var activeSessionId: UUID?

    /// 当前权限模式
    @Published var permissionMode: PermissionMode = BaizePermission.defaultMode

    /// 当前 Agent 事件（用于 UI 实时更新）
    @Published var lastAgentEvent: AgentEventPlaceholder?

    // MARK: - API Configuration

    /// API Key 是否已配置（至少一个 Provider）
    @Published var apiConfigured: Bool = false

    /// 当前使用的 API Provider
    @Published var activeProvider: APIProvider = .openAI

    /// 当前使用的模型
    @Published var activeModel: String = BaizeAPI.defaultModel

    /// 自定义 Provider 的端点 URL
    @Published var customEndpoint: String = BaizeAPI.deepSeekEndpoint

    /// 自定义 Provider 的模型名
    @Published var customModel: String = "deepseek-chat"

    /// 自定义 Provider 的 contextWindow（Bug 3: Custom Provider 无 ModelInfo，需用户手动配置）
    /// 默认 128_000，从 UserDefaults 读取，didSet 时写回
    @Published var customContextWindow: Int = {
        let stored = UserDefaults.standard.integer(forKey: BaizeAPI.customContextWindowUDKey)
        return stored > 0 ? stored : 128_000
    }() {
        didSet {
            UserDefaults.standard.set(customContextWindow, forKey: BaizeAPI.customContextWindowUDKey)
            // 配置变更后触发节流备份到 config.json
            Task { await ConfigBackupService.shared.scheduleBackup() }
        }
    }

    // MARK: - Shared Services (W22 fix: DI 注入点)

    /// Keychain 安全存储服务
    var keychainService: KeychainService?

    /// API Gateway（actor）
    var apiGateway: APIGateway?

    /// Tool Registry（actor）
    var toolRegistry: ToolRegistry?

    /// Permission Engine
    var permissionEngine: PermissionEngine?

    /// Project Context（class 引用类型，load() 变更即时持久化）
    var projectContext: ProjectContext?

    /// Context Manager
    var contextManager: ContextManager?

    /// Conversation Store（actor，W1 fix: 防止并发数据竞争）
    var conversationStore: ConversationStore?

    /// File System Service
    var fileSystemService: FileSystemService?

    /// T01: Platform File System（actor，T02 将替换 FileSystemService）
    var platformFileSystem: PlatformFileSystem?

    /// Runtime Executor
    var runtimeExecutor: RuntimeExecutor?

    /// Python Runtime Engine（P3 诊断面板：供设置页读取引擎诊断状态）
    var pythonRuntimeEngine: PythonRuntimeEngine?

    /// Monaco Bridge（Monaco 诊断面板：供设置页读取编辑器加载诊断状态）
    /// 由 EditorContainerView 在 setupMonacoBridge() 中注入
    var monacoBridge: MonacoBridge?

    /// Git Service（actor，封装 libgit2 C API）
    var gitService: GitService?

    /// Git ViewModel（@MainActor ObservableObject，Git Tab UI 状态管理）
    var gitViewModel: GitViewModel?

    /// Terminal ViewModel（@MainActor ObservableObject，终端面板状态管理）
    /// BaizeApp.init() 中创建一次，App 生命周期内不销毁
    var terminalViewModel: TerminalViewModel?

    /// T03: Project Registry — 项目注册表（actor，持久化项目列表）
    var projectRegistry: ProjectRegistry?

    /// T03: Usage Tracker — 用量统计（actor，T04 会深度集成）
    var usageTracker: UsageTracker?

    /// T03: Editor State — 编辑器状态引用（用于切换项目时检查未保存改动 + 清空 Tab）
    /// 由 EditorContainerView 在初始化时注入
    var editorState: EditorState?

    // MARK: - R1/R2 新增服务引用（T02/T03/T04 补全实现后注入）

    /// Skills 注册表（actor）— T02 补全实现后注入
    var skillRegistry: SkillRegistry?

    /// Memory 存储（actor）— T02 补全实现后注入
    var memoryStore: MemoryStore?

    /// Slash 命令注册表（actor）— T02 补全实现后注入
    var commandRegistry: CommandRegistry?

    /// PlanMode 状态机（actor）— T02 补全实现后注入
    var planModeState: PlanModeState?

    /// 网络搜索 Provider（protocol）— T02 补全实现后注入
    var webSearchProvider: WebSearchProvider?

    /// 共享任务列表（actor）— T04 补全实现后注入
    var taskList: TaskList?

    /// 团队协调器（actor）— T04 补全实现后注入
    var teamCoordinator: TeamCoordinator?

    /// MCP 连接管理器（actor）— T04 补全实现后注入
    var mcpManager: MCPManager?

    // MARK: - R1 UI State（PlanMode/AskUserQuestion/Todo 等 UI 交互状态）

    /// TodoWrite 工具维护的任务清单（供 TaskListView 显示）
    @Published var todoItems: [TodoItem] = []

    /// PlanMode 是否激活（UI 显示"计划模式"标识）
    @Published var isPlanModeActive: Bool = false

    /// 待审批的计划文本
    @Published var pendingPlanForApproval: String? = nil

    /// 是否显示 PlanMode 审批弹窗
    @Published var showPlanApprovalSheet: Bool = false

    /// 待回答的结构化问题列表
    @Published var pendingQuestions: [UserQuestion]? = nil

    /// 是否显示结构化提问弹窗
    @Published var showAskUserQuestionSheet: Bool = false

    // MARK: - Error State

    /// 最近错误消息（用于全局 Alert）
    @Published var errorMessage: String?

    /// 是否显示错误 Alert
    @Published var showErrorAlert: Bool = false

    // MARK: - Initialization

    init() {
        // 检查默认项目目录是否存在
        ensureProjectDirectoryExists()
    }

    // MARK: - Provider & Model Management

    /// 设置当前活跃的 Provider 和模型
    /// - Parameters:
    ///   - provider: API Provider
    ///   - model: 模型名称
    func setActiveProvider(_ provider: APIProvider, model: String) {
        activeProvider = provider
        activeModel = model
        persistProviderSelection()

        // 异步通知 APIGateway
        Task {
            do {
                try await apiGateway?.setActiveProvider(providerId: provider.providerId, model: model)
                baizeLogger.info("Active provider set to '\(provider.displayName)' with model '\(model)'")
            } catch {
                baizeLogger.error("Failed to set active provider on APIGateway: \(error.localizedDescription)")
            }
        }
    }

    /// 持久化 Provider/Model 选择到 UserDefaults
    private func persistProviderSelection() {
        UserDefaults.standard.set(activeProvider.rawValue, forKey: "com.baize.active-provider")
        UserDefaults.standard.set(activeModel, forKey: "com.baize.active-model")

        // 配置变更后触发节流备份到 config.json（TrollStore 重装保命）
        Task { await ConfigBackupService.shared.scheduleBackup() }
    }

    /// 从 UserDefaults 恢复 Provider/Model 选择
    func restoreProviderSelection() {
        if let rawValue = UserDefaults.standard.string(forKey: "com.baize.active-provider"),
           let provider = APIProvider(rawValue: rawValue) {
            activeProvider = provider
        }
        if let model = UserDefaults.standard.string(forKey: "com.baize.active-model") {
            activeModel = model
        }
    }

    /// 持久化自定义端点和模型名到 UserDefaults
    func persistCustomConfig() {
        UserDefaults.standard.set(customEndpoint, forKey: BaizeAPI.customEndpointUDKey)
        UserDefaults.standard.set(customModel, forKey: BaizeAPI.customModelUDKey)

        // 配置变更后触发节流备份到 config.json
        Task { await ConfigBackupService.shared.scheduleBackup() }
    }

    /// 从 UserDefaults 恢复自定义端点和模型名
    func restoreCustomConfig() {
        if let endpoint = UserDefaults.standard.string(forKey: BaizeAPI.customEndpointUDKey) {
            customEndpoint = endpoint
        }
        if let model = UserDefaults.standard.string(forKey: BaizeAPI.customModelUDKey) {
            customModel = model
        }
    }

    // MARK: - Methods

    /// 打开文件（添加到 Tab 列表 + 设为选中）
    func openFile(at path: String) {
        if !openFiles.contains(path) {
            openFiles.append(path)
        }
        selectedFilePath = path
    }

    /// 关闭文件 Tab
    func closeFile(at path: String) {
        openFiles.removeAll { $0 == path }
        if selectedFilePath == path {
            selectedFilePath = openFiles.last
        }
    }

    /// 切换到指定 Tab
    func switchToTab(_ tab: AppTab) {
        selectedTab = tab
    }

    /// 显示全局错误 Alert
    func showError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }

    /// 设置 API 配置状态
    func updateAPIStatus(isConfigured: Bool) {
        apiConfigured = isConfigured
    }

    // MARK: - T03: Project Switching

    /// T03: 切换当前项目，触发全子系统联动（10 步）
    ///
    /// 切换流程：
    /// 1. 检查是否已在当前项目（是则跳过）
    /// 2. 检查编辑器未保存改动 → 自动保存
    /// 3. 更新 currentProjectPath
    /// 4. 更新 FileSystemService 根路径
    /// 5. 更新 ProjectContext 根路径 + 重新加载 BAIZE.md
    /// 6. 重建 GitService 实例（repositoryPath 是 let，必须新建）
    /// 7. 重建 GitViewModel（持有新 GitService）
    /// 8. 更新 TerminalViewModel 工作目录
    /// 9. 更新 RuntimeExecutor ios_setMiniRoot（进程级）
    /// 10. 更新 ProjectRegistry lastOpened + 清空编辑器 Tab
    ///
    /// - Parameter projectPath: 新项目的绝对路径
    func switchProject(to projectPath: String) async {
        // Step 1: 检查是否已在当前项目
        guard projectPath != currentProjectPath else {
            baizeLogger.info("switchProject: already at target path, skipping")
            return
        }

        baizeLogger.info("switchProject: switching from '\(self.currentProjectPath)' to '\(projectPath)'")

        // Step 2: 检查编辑器未保存改动 → 自动保存
        if let editor = editorState, editor.hasUnsavedChanges {
            if let activeTab = editor.activeTab {
                let content = editor.currentContent
                do {
                    try fileSystemService?.writeFile(at: activeTab.filePath, content: content)
                    editor.markSaved()
                    baizeLogger.info("switchProject: auto-saved '\(activeTab.fileName)' before switching")
                } catch {
                    baizeLogger.error("switchProject: failed to auto-save '\(activeTab.fileName)': \(error.localizedDescription)")
                }
            }
        }

        // Step 3: 更新 currentProjectPath
        currentProjectPath = projectPath

        // Step 4: 更新 FileSystemService 根路径
        fileSystemService?.updateRootPath(projectPath)

        // Step 5: 更新 ProjectContext 根路径 + 重新加载 BAIZE.md
        if let projectCtx = projectContext {
            await projectCtx.updateRootPath(projectPath)
        }

        // Step 6: 重建 GitService 实例（repositoryPath 是 let，必须新建）
        if let keychain = keychainService {
            let newGitService = GitService(repositoryPath: projectPath, keychainService: keychain)
            // Step 7: 重建 GitViewModel（持有新 GitService）
            let newGitVM = GitViewModel(gitService: newGitService)
            gitService = newGitService
            gitViewModel = newGitVM
            baizeLogger.info("switchProject: GitService + GitViewModel rebuilt for '\(projectPath)'")
        }

        // Step 8: 更新 TerminalViewModel 工作目录
        terminalViewModel?.currentWorkingDir = projectPath

        // Step 9: 更新 RuntimeExecutor ios_setMiniRoot（进程级）
        runtimeExecutor?.updateProjectRoot(projectPath)

        // Step 10: 更新 ProjectRegistry lastOpened + 清空编辑器 Tab
        if let registry = projectRegistry {
            if let entry = await registry.find(path: projectPath) {
                var updated = entry
                updated.lastOpened = Date()
                await registry.update(updated)
                baizeLogger.info("switchProject: updated lastOpened for '\(entry.name)'")
            }
        }

        // 清空编辑器 Tab 和 AppState 打开文件列表
        editorState?.openTabs = []
        editorState?.activeTab = nil
        editorState?.hasUnsavedChanges = false
        openFiles = []
        selectedFilePath = nil

        // Bug 3 fix: 持久化当前项目路径到 UserDefaults，
        // App 重启后恢复上次的项目路径，确保终端历史等按项目隔离的数据能正确加载
        UserDefaults.standard.set(projectPath, forKey: BaizeGit.lastProjectPathUDKey)

        baizeLogger.info("switchProject: completed switch to '\(projectPath)'")
    }

    /// T03: 注册当前项目到 ProjectRegistry（首次启动时调用）
    /// 如果当前项目路径尚未注册，创建 ProjectEntry 并添加
    func registerCurrentProject() async {
        guard let registry = projectRegistry else {
            baizeLogger.warning("registerCurrentProject: projectRegistry is nil, skipping")
            return
        }

        let path = currentProjectPath

        // 检查是否已注册
        if let existing = await registry.find(path: path) {
            // 已注册，更新 lastOpened
            var updated = existing
            updated.lastOpened = Date()
            await registry.update(updated)
            baizeLogger.info("registerCurrentProject: project already registered, updated lastOpened")
            return
        }

        // 未注册，创建新条目
        let projectName = (path as NSString).deletingLastPathComponent.isEmpty
            ? "Baize"
            : (path as NSString).lastPathComponent

        let entry = ProjectEntry(
            id: UUID(),
            name: projectName,
            path: path,
            stack: "Unknown",
            icon: "folder.fill",
            lastOpened: Date()
        )
        await registry.add(entry)
        baizeLogger.info("registerCurrentProject: registered '\(projectName)' at \(path)")
    }

    /// 确保 BaiZe 项目目录存在
    /// 优先尝试 TrollStore no-sandbox 路径，失败则回退到 App 沙箱 Documents 目录
    private func ensureProjectDirectoryExists() {
        let fm = FileManager.default

        // Try creating the TrollStore no-sandbox path first
        do {
            try fm.ensureDirectoryExists(atPath: BaizePath.projectRoot)
            try fm.ensureDirectoryExists(atPath: BaizePath.internalData)
            try fm.ensureDirectoryExists(atPath: BaizePath.conversations)
            // Bug 5 fix: 确保终端历史和用量数据目录存在
            try fm.ensureDirectoryExists(atPath: BaizePath.terminalHistory)
            try fm.ensureDirectoryExists(atPath: BaizePath.usageData)
        } catch {
            // Fallback: use the app's Documents directory (sandboxed but always works)
            let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
            let fallbackRoot = (docsDir as NSString).appendingPathComponent("Baize")
            let fallbackInternal = (fallbackRoot as NSString).appendingPathComponent(".baize")
            let fallbackConv = (fallbackInternal as NSString).appendingPathComponent("conversations")
            let fallbackTermHistory = (fallbackInternal as NSString).appendingPathComponent("terminal_history")
            let fallbackUsage = (fallbackInternal as NSString).appendingPathComponent("usage")
            try? fm.ensureDirectoryExists(atPath: fallbackRoot)
            try? fm.ensureDirectoryExists(atPath: fallbackInternal)
            try? fm.ensureDirectoryExists(atPath: fallbackConv)
            try? fm.ensureDirectoryExists(atPath: fallbackTermHistory)
            try? fm.ensureDirectoryExists(atPath: fallbackUsage)
            // Update the current project path to the fallback
            currentProjectPath = fallbackRoot + "/"
            baizeLogger.info("Using fallback project directory: \(self.currentProjectPath)")
        }
    }
}

// MARK: - API Provider Enum

/// 支持的 API 服务提供商
enum APIProvider: String, CaseIterable, Codable {
    case openAI
    case anthropic
    case openRouter
    case custom

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .custom: return "自定义 (OpenAI 兼容)"
        }
    }

    /// Provider ID — 与 LLMProvider.id 一致，用于 APIGateway 查找
    var providerId: String {
        switch self {
        case .openAI: return "openai"
        case .anthropic: return "anthropic"
        case .openRouter: return "openrouter"
        case .custom: return "custom"
        }
    }

    var keychainKey: String {
        switch self {
        case .openAI: return BaizeAPI.openAIKeyKeychainKey
        case .anthropic: return BaizeAPI.anthropicKeyKeychainKey
        case .openRouter: return BaizeAPI.openRouterKeyKeychainKey
        case .custom: return BaizeAPI.customProviderKeyKeychainKey
        }
    }
}

// MARK: - Agent Event Placeholder (Phase 1)

/// Agent 事件占位类型 — Phase 1 简化版
/// Phase 2(T02): 替换为完整的 AgentEvent enum
struct AgentEventPlaceholder: Identifiable {
    let id = UUID()
    let type: String
    let content: String
}
