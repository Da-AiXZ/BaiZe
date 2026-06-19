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
                }
            }
            .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.systemImage) }
            .tag(AppTab.workspace)

            // Tab 2: Git — 独立 NavigationStack
            NavigationStack {
                if let gitVM = appState.gitViewModel {
                    GitStatusView(viewModel: gitVM)
                } else {
                    Text("Git 服务未初始化")
                        .foregroundColor(.secondary)
                }
            }
            .tabItem { Label(AppTab.git.title, systemImage: AppTab.git.systemImage) }
            .tag(AppTab.git)

            // Tab 3: 首页 — 独立 NavigationStack
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label(AppTab.dashboard.title, systemImage: AppTab.dashboard.systemImage) }
            .tag(AppTab.dashboard)

            // Tab 4: 设置 — 独立 NavigationStack（子页面用 NavigationLink 推入，不逃逸）
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
        // Bug 4 fix: FocusModeBar 移到右上角，避免挡住 Agent 状态显示
        .overlay(alignment: .topTrailing) {
            FocusModeBar(focusMode: $appState.focusMode, isAgentRunning: appState.isAgentRunning)
                .padding(.top, 4)
                .padding(.trailing, 8)
        }
        .animation(.easeInOut(duration: 0.3), value: appState.focusMode)
    }
}

// MARK: - Focus Mode Bar (Bug 1 fix)

/// 焦点模式切换控件 — 浮动在 WorkspacePane 右上角
/// 用户一眼可见，支持代码/对话/平衡三种模式
/// Agent 运行时锁定为对话模式，运行结束后用户可手动切换
private struct FocusModeBar: View {
    @Binding var focusMode: FocusMode
    let isAgentRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FocusMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        focusMode = mode
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 12, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        focusMode == mode
                            ? Color.baizeAccent
                            : Color.clear
                    )
                    .foregroundColor(
                        focusMode == mode
                            ? .white
                            : .secondary
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isAgentRunning && mode != .chat)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
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
