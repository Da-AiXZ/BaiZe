import SwiftUI

/// 白泽核心工作区 — TabView 顶层导航 + 两栏 NavigationSplitView + 焦点驱动工作区
/// 重构：三栏 SplitView + ⋯菜单 sheet → TabView 三 Tab + 两栏 SplitView + WorkspacePane
/// 焦点切换：Agent 运行时自动切换到对话面板焦点（.chat），用户可手动切回代码焦点
struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showNewProjectWizard = false
    @State private var projectList: [ProjectEntry] = []
    @State private var showRightSidebar: Bool = false
    @State private var showDashboardSheet: Bool = false
    @State private var showWorkbenchSheet: Bool = false
    @State private var showSettingsSheet: Bool = false

    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        // R3 重构：横屏用 HSplitView（聊天 + 工作台），竖屏用 TabView + 抽屉
        Group {
            if horizontalSizeClass == .regular {
                // 横屏：NavigationSplitView（文件浏览器 + HSplitView(工作区 + 工作台)）
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    FileExplorerView(appState: appState)
                        .navigationTitle("项目文件")
                } detail: {
                    R3WorkspacePane(
                        appState: appState,
                        showRightSidebar: $showRightSidebar,
                        onDashboard: {
                            withAnimation(.easeInOut(duration: 0.3)) { showRightSidebar = false }
                            showDashboardSheet = true
                        },
                        onWorkbench: {
                            withAnimation(.easeInOut(duration: 0.3)) { showRightSidebar = false }
                            showWorkbenchSheet = true
                        },
                        onSettings: {
                            withAnimation(.easeInOut(duration: 0.3)) { showRightSidebar = false }
                            showSettingsSheet = true
                        }
                    )
                        .safeAreaInset(edge: .top, spacing: 0) {
                            topBar
                        }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // 竖屏：保留 TabView 布局 + 工作台作为独立 Tab
                TabView(selection: $appState.selectedTab) {
                    NavigationStack {
                        WorkspacePane(appState: appState)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                topBar
                            }
                    }
                    .tabItem { Label(AppTab.workspace.title, systemImage: AppTab.workspace.systemImage) }
                    .tag(AppTab.workspace)

                    NavigationStack {
                        WorkbenchSidebar(appState: appState)
                            .navigationTitle("工作台")
                    }
                    .tabItem { Label("工作台", systemImage: "sidebar.right") }
                    .tag(AppTab.git)

                    NavigationStack {
                        DashboardView()
                    }
                    .tabItem { Label(AppTab.dashboard.title, systemImage: AppTab.dashboard.systemImage) }
                    .tag(AppTab.dashboard)

                    NavigationStack {
                        SettingsView(appState: appState)
                    }
                    .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                    .tag(AppTab.settings)
                }
                .tint(Color.baizeAccent)
            }
        }
        // Agent 运行时自动切换焦点到对话面板
        // Bug 5 fix: 使用 withAnimation 包裹，替代原 WorkspacePane 上的 .animation 修饰符
        // （.animation 已移除以避免动画传导到 ChatView 内部长内容全量重绘）
        .onChange(of: appState.isAgentRunning) { running in
            if running {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState.focusMode = .chat
                }
            }
        }
        // 全局错误 Alert
        .alert("错误", isPresented: $appState.showErrorAlert) {
            Button("确定") { appState.showErrorAlert = false }
        } message: {
            Text(appState.errorMessage ?? "未知错误")
        }
        // T03: 新建项目向导 Sheet
        .sheet(isPresented: $showNewProjectWizard) {
            NewProjectWizard(appState: appState)
        }
        // iPad BugFix: 首页 Sheet（从右侧栏入口弹出）
        .sheet(isPresented: $showDashboardSheet) {
            NavigationStack {
                DashboardView()
                    .environmentObject(appState)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showDashboardSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // iPad BugFix: 工作台 Sheet（从右侧栏入口弹出）
        .sheet(isPresented: $showWorkbenchSheet) {
            NavigationStack {
                WorkbenchSidebar(appState: appState)
                    .navigationTitle("工作台")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showWorkbenchSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // iPad BugFix: 设置 Sheet（从右侧栏入口弹出）
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsView(appState: appState)
                    .navigationTitle("设置")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showSettingsSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // T03: 启动时加载项目列表 + 项目路径变化时刷新
        .task {
            await refreshProjectList()
        }
        .onChange(of: appState.currentProjectPath) { _ in
            Task { await refreshProjectList() }
        }
    }

    // MARK: - R3 Top Bar

    /// 顶部工具栏 — 项目切换 + 焦点模式 + 右侧栏开关 + Agent 状态
    private var topBar: some View {
        HStack(spacing: 8) {
            ProjectSwitcherMenu(
                appState: appState,
                projectList: projectList,
                onNewProject: { showNewProjectWizard = true },
                onSwitchProject: { path in
                    Task { await appState.switchProject(to: path) }
                },
                onRefreshList: { Task { await refreshProjectList() } }
            )

            Spacer()

            FocusModeBar(focusMode: $appState.focusMode, isAgentRunning: appState.isAgentRunning)

            // iPad BugFix: 右侧栏开关按钮（仅横屏显示，替代原工作台开关）
            // 点击后 detail 右侧滑出 240pt 面板（首页/工作台/设置）
            if horizontalSizeClass == .regular {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showRightSidebar.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(showRightSidebar ? .baizeAccent : .secondary)
                        .padding(6)
                        .background(showRightSidebar ? Color.baizeAccent.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            AgentStatusIndicator(isRunning: appState.isAgentRunning)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemBackground).opacity(0.95))
    }

    // MARK: - T03: Project List Refresh

    /// 从 ProjectRegistry 加载项目列表到本地 @State
    private func refreshProjectList() async {
        guard let registry = appState.projectRegistry else { return }
        let list = await registry.list()
        await MainActor.run { self.projectList = list }
    }
}

// MARK: - Workspace Pane (编辑器 + 对话面板, 焦点驱动宽度)

/// 工作区面板 — 自定义 HStack，内含编辑器和对话面板
/// 通过 FocusMode 枚举控制宽度比，withAnimation 实现平滑过渡（Bug 5: 动画范围隔离）
private struct WorkspacePane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 编辑器 + 对话面板（焦点驱动宽度）
                // Bug 5 fix: .transaction 隔离终端展开/折叠时的高度变化动画，
                // 防止动画传导到 HStack 内部的 ChatMessageList 长内容全量重绘
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
                .frame(maxHeight: .infinity)
                .transaction { t in t.animation = nil }

                // 终端面板（底部，可折叠/展开）
                // TerminalPane 内部管理高度（折叠 36pt / 展开 35%），
                // VStack 自动将剩余空间分配给上方 HStack
                if let terminalVM = appState.terminalViewModel {
                    TerminalPane(viewModel: terminalVM, availableHeight: geo.size.height)
                }
            }
        }
        // Bug B fix: FocusModeBar 使用 safeAreaInset 固定在 detail 顶部，不再使用 overlay 或 toolbar
        // Bug 5 fix: 移除 .animation(.easeInOut(duration: 0.3), value: appState.focusMode)
        // 原因：该 .animation 作用于整个 WorkspacePane，导致 focusMode 切换时 ChatView 内部
        // ChatMessageList（长内容 ScrollView）也参与宽度动画重绘 → 18 帧全量重布局 → 卡顿。
        // 动画范围隔离改在 ChatMessageList 内部用 .transaction 实现（见 ChatView.swift）。
    }
}

// MARK: - R3 Workspace Pane (横屏: 工作区 + 右侧导航栏)

/// R3 横屏工作区面板 — 编辑器/对话 + 右侧导航栏（首页/工作台/设置入口）
/// iPad BugFix: 原右侧 360pt 工作台侧栏改为 240pt 右侧导航栏，
/// 工作台/首页/设置改为通过 sheet 弹出，解决 iPad regular 分支入口缺失问题。
@MainActor
private struct R3WorkspacePane: View {
    @ObservedObject var appState: AppState
    @Binding var showRightSidebar: Bool
    let onDashboard: () -> Void
    let onWorkbench: () -> Void
    let onSettings: () -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // 左侧：工作区（编辑器 + 对话 + 终端）
                WorkspacePane(appState: appState)
                    .frame(width: showRightSidebar ? geo.size.width - 240 : geo.size.width)

                // 右侧：导航栏（首页/工作台/设置入口）
                if showRightSidebar {
                    Divider()
                        .background(Color.baizeBorder)
                    RightSidebar(
                        appState: appState,
                        onDashboard: onDashboard,
                        onWorkbench: onWorkbench,
                        onSettings: onSettings
                    )
                    .frame(width: 240)
                }
            }
        }
    }
}

// MARK: - Right Sidebar (iPad BugFix: 首页/工作台/设置入口)

/// 右侧导航栏 — 240pt 宽，垂直排列三个入口（首页/工作台/设置）
/// 风格与左侧"项目文件"栏一致：浅色背景、分隔线、图标 + 文字行
/// 点击入口：收起右侧栏 + 弹对应 sheet（由 ContentView 传入的闭包处理）
private struct RightSidebar: View {
    let appState: AppState
    let onDashboard: () -> Void
    let onWorkbench: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（与左侧"项目文件"风格一致）
            HStack {
                Text("导航")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Color.baizeBorder)

            // 三个入口
            VStack(spacing: 0) {
                RightSidebarRow(title: "首页", icon: "square.grid.2x2", action: onDashboard)
                Divider().background(Color.baizeBorder.opacity(0.5)).padding(.leading, 46)
                RightSidebarRow(title: "工作台", icon: "sidebar.right", action: onWorkbench)
                Divider().background(Color.baizeBorder.opacity(0.5)).padding(.leading, 46)
                RightSidebarRow(title: "设置", icon: "gearshape", action: onSettings)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 240)
        .background(Color(.systemBackground))
    }
}

/// 右侧导航栏行 — 图标 + 文字 + 右箭头，点击有高亮反馈
private struct RightSidebarRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.baizeAccent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(RightSidebarRowStyle())
    }
}

/// 右侧导航栏行按钮样式 — 按下时高亮背景
private struct RightSidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.baizeAccent.opacity(0.12) : Color.clear)
    }
}

// MARK: - Focus Mode Bar (Bug 1 fix)

/// 焦点模式切换控件 — 使用 safeAreaInset 固定在 detail 顶部右侧
/// 与侧栏标题同一高度，不遮挡内容区的模型/权限选择器
/// Agent 运行时锁定为对话模式，运行结束后用户可手动切换
private struct FocusModeBar: View {
    @Binding var focusMode: FocusMode
    let isAgentRunning: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FocusMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        focusMode = mode
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
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
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isAgentRunning && mode != .chat)
            }
        }
        .padding(2)
        .background(Color(.systemBackground).opacity(0.8))
        .cornerRadius(8)
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

// MARK: - T03: Project Switcher Menu

/// 项目切换下拉菜单 — 显示当前项目名 + 所有项目列表 + 新建项目入口
/// 放置在 FocusModeBar 左侧，通过 HStack 排列确保不互相遮挡
private struct ProjectSwitcherMenu: View {
    @ObservedObject var appState: AppState
    let projectList: [ProjectEntry]
    let onNewProject: () -> Void
    let onSwitchProject: (String) -> Void
    let onRefreshList: () -> Void

    /// 当前项目名（从路径提取最后一级目录名）
    private var currentProjectName: String {
        let path = appState.currentProjectPath
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "Baize" : name
    }

    var body: some View {
        Menu {
            // 项目列表
            Section("项目") {
                ForEach(projectList) { entry in
                    Button(action: {
                        onSwitchProject(entry.path)
                    }) {
                        HStack {
                            Image(systemName: entry.icon)
                            Text(entry.name)
                            if entry.path == appState.currentProjectPath {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // 新建项目
            Section {
                Button(action: onNewProject) {
                    Label("新建项目", systemImage: "plus.circle")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.baizeAccent)
                Text(currentProjectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.systemBackground).opacity(0.8))
            .cornerRadius(8)
        }
        .onAppear {
            onRefreshList()
        }
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
