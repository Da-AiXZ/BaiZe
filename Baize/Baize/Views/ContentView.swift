import SwiftUI

/// 白泽核心工作区 — 三栏布局 NavigationSplitView
/// T05: 端到端集成 — 事件流连接、面板联动、依赖注入
/// 左栏：文件浏览器 | 中栏：代码编辑器(Monaco) | 右栏：对话面板
/// 面板联动：Agent 调用 read_file → 自动在 Monaco Editor 中打开该文件
///          Agent 调用 write_file/edit_file → 编辑器自动刷新
struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左栏：文件浏览器 + Dashboard + 设置导航
            SidebarPane(appState: appState)
        } content: {
            // 中栏：代码编辑器（集成 MonacoBridge）
            EditorPane(appState: appState)
        } detail: {
            // 右栏：对话面板（集成 AgentLoop 事件流）
            ChatPane(appState: appState)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ToolbarActions(appState: appState)
            }
        }
        // 全局错误 Alert
        .alert("错误", isPresented: $appState.showErrorAlert) {
            Button("确定") { appState.showErrorAlert = false }
        } message: {
            Text(appState.errorMessage ?? "未知错误")
        }
    }
}

// MARK: - Sidebar Pane (左栏)

/// 左栏聚合：文件浏览器 + Dashboard + 设置导航
/// T05: 传递 appState 到 FileExplorerView（支持面板联动）
private struct SidebarPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List {
            NavigationLink(destination: DashboardView()) {
                Label("首页", systemImage: "house")
            }

            NavigationLink(destination: FileExplorerView(appState: appState)) {
                Label("文件", systemImage: "folder")
            }

            NavigationLink(destination: FileSearchView(appState: appState)) {
                Label("搜索", systemImage: "magnifyingglass")
            }

            NavigationLink(destination: SettingsView(appState: appState)) {
                Label("设置", systemImage: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("白泽")
    }
}

// MARK: - Editor Pane (中栏)

/// 中栏：Monaco Editor 容器视图
/// T05: 传递 appState → EditorContainerView → MonacoBridge
/// 当 Agent 修改文件后，编辑器自动刷新
private struct EditorPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        EditorContainerView(appState: appState)
    }
}

// MARK: - Chat Pane (右栏)

/// 右栏：对话面板
/// T05: 传递 appState → ChatView → AgentLoop 事件流订阅
/// Agent 事件 → 消息气泡渲染 → 工具执行后刷新 FileExplorerView 和 EditorView
private struct ChatPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ChatView(appState: appState)
    }
}

// MARK: - Toolbar Actions

/// 工具栏按钮：Agent 状态指示 + 连接状态 + 快捷操作
/// T05: 集成完整的 Agent 运行状态指示和 API 连接检测
private struct ToolbarActions: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Agent 运行状态指示器
            AgentStatusIndicator(isRunning: appState.isAgentRunning)

            // API 连接状态
            ConnectionStatusBadge(isConfigured: appState.apiConfigured)

            // 权限模式徽章
            PermissionModeBadge(mode: appState.permissionMode)
        }
    }
}

/// Agent Loop 运行状态指示器（脉冲动画）
struct AgentStatusIndicator: View {
    let isRunning: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(isRunning ? Color.baizeAccent : Color.gray.opacity(0.5))
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.baizeAccent, lineWidth: 2)
                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                    .opacity(isPulsing ? 0.4 : 0.0)
            )
            .animation(isRunning ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: isPulsing)
            .onChange(of: isRunning) { running in
                isPulsing = running
            }
            .help(isRunning ? "Agent 正在运行" : "Agent 待命")
    }
}

/// API 连接状态徽章
struct ConnectionStatusBadge: View {
    let isConfigured: Bool

    var body: some View {
        Image(systemName: isConfigured ? "wifi" : "wifi.slash")
            .foregroundColor(isConfigured ? Color.green : Color.red.opacity(0.7))
            .help(isConfigured ? "API 已连接" : "API 未配置")
    }
}

/// 权限模式徽章 — 显示当前权限模式缩写
private struct PermissionModeBadge: View {
    let mode: PermissionMode

    var body: some View {
        Text(mode.shortName)
            .font(.caption2)
            .foregroundColor(mode.badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(mode.badgeColor.opacity(0.15))
            .cornerRadius(3)
            .help(mode.description)
    }
}

// MARK: - PermissionMode UI Extensions

extension PermissionMode {
    /// 权限模式缩写（用于 Toolbar Badge）
    var shortName: String {
        switch self {
        case .default: return "D"
        case .acceptEdits: return "E"
        case .plan: return "P"
        case .bypass: return "B"
        }
    }

    /// 权限模式徽章颜色
    var badgeColor: Color {
        switch self {
        case .default: return .secondary
        case .acceptEdits: return .green
        case .plan: return .blue
        case .bypass: return .red
        }
    }
}