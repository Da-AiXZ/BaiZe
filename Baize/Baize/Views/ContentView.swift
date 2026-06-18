import SwiftUI

/// 白泽核心工作区 — TabView 顶层导航 + 两栏 NavigationSplitView + 焦点驱动工作区
/// 重构：三栏 SplitView + ⋯菜单 sheet → TabView 三 Tab + 两栏 SplitView + WorkspacePane
/// 焦点切换：Agent 运行时自动切换到对话面板焦点（.chat），用户可手动切回代码焦点
struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            // Tab 1: 工作区 — 两栏 NavigationSplitView
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // 左栏：文件浏览器（sidebar, 可滑出）
                FileExplorerView(appState: appState)
                    .navigationTitle("项目文件")
            } detail: {
                // 右栏：工作区面板（编辑器 + 对话面板，焦点驱动宽度）
                WorkspacePane(appState: appState)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Agent 运行状态指示器（脉冲圆点）
                    AgentStatusIndicator(isRunning: appState.isAgentRunning)

                    // 焦点模式分段控件（代码 | 对话）
                    Picker("焦点", selection: $appState.focusMode) {
                        Text("代码").tag(FocusMode.code)
                        Text("对话").tag(FocusMode.chat)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
            .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.systemImage) }
            .tag(AppTab.workspace)

            // Tab 2: 首页 — 独立 NavigationStack
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label(AppTab.dashboard.title, systemImage: AppTab.dashboard.systemImage) }
            .tag(AppTab.dashboard)

            // Tab 3: 设置 — 独立 NavigationStack（子页面用 NavigationLink 推入，不逃逸）
            NavigationStack {
                SettingsView(appState: appState)
            }
            .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
            .tag(AppTab.settings)
        }
        .tint(Color.baizeAccent)
        // Agent 运行时自动切换焦点到对话面板
        .onChange(of: appState.isAgentRunning) { running in
            if running {
                appState.focusMode = .chat
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

// MARK: - Workspace Pane (编辑器 + 对话面板, 焦点驱动宽度)

/// 工作区面板 — 自定义 HStack，内含编辑器和对话面板
/// 通过 FocusMode 枚举控制宽度比，.animation 实现平滑过渡
private struct WorkspacePane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // 编辑器（Monaco）
                EditorContainerView(appState: appState)
                    .frame(width: geo.size.width * appState.focusMode.editorRatio)

                // 分隔线
                Divider()
                    .background(Color.baizeBorder)

                // 对话面板（Agent 对话）
                ChatView(appState: appState)
                    .frame(width: geo.size.width * appState.focusMode.chatRatio)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.focusMode)
    }
}

// MARK: - Agent Status Indicator

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

// MARK: - PermissionMode UI Extensions

extension PermissionMode {
    /// 权限模式缩写（用于 Badge）
    var shortName: String {
        switch self {
        case .default: return "D"
        case .acceptEdits: return "E"
        case .plan: return "P"
        case .bypass: return "B"
        }
    }

    /// 权限模式徽章颜色 — DeepSeek 蓝白配色
    var badgeColor: Color {
        switch self {
        case .default: return .secondary
        case .acceptEdits: return Color.baizeSuccess
        case .plan: return Color.baizeAccent
        case .bypass: return Color.baizeError
        }
    }
}
