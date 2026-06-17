import SwiftUI
import Foundation

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

    /// Conversation Store
    var conversationStore: ConversationStore?

    /// File System Service
    var fileSystemService: FileSystemService?

    /// Runtime Executor
    var runtimeExecutor: RuntimeExecutor?

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

    /// 显示全局错误 Alert
    func showError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }

    /// 设置 API 配置状态
    func updateAPIStatus(isConfigured: Bool) {
        apiConfigured = isConfigured
    }

    /// 确保 BaiZe 项目目录存在
    private func ensureProjectDirectoryExists() {
        let fm = FileManager.default
        try? fm.ensureDirectoryExists(atPath: BaizePath.projectRoot)
        try? fm.ensureDirectoryExists(atPath: BaizePath.internalData)
        try? fm.ensureDirectoryExists(atPath: BaizePath.conversations)
    }
}

// MARK: - API Provider Enum

/// 支持的 API 服务提供商
enum APIProvider: String, CaseIterable, Codable {
    case openAI
    case anthropic
    case openRouter

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        }
    }

    var keychainKey: String {
        switch self {
        case .openAI: return BaizeAPI.openAIKeyKeychainKey
        case .anthropic: return BaizeAPI.anthropicKeyKeychainKey
        case .openRouter: return BaizeAPI.openRouterKeyKeychainKey
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