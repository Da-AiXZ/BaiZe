import SwiftUI

/// 设置页完整视图 — 独立 Tab + NavigationStack + NavigationLink 导航
/// 重构：从 @State selectedSection + 自定义返回按钮模式改为标准 NavigationLink + navigationDestination
/// 设置作为独立 Tab 拥有自己的 NavigationStack，NavigationLink 自然推入当前 Stack，不会逃逸到对话面板
struct SettingsView: View {
    @ObservedObject var appState: AppState

    /// Git 配置显示文本 — 用 @State 存储，.onAppear 时从 UserDefaults 重新读取
    /// 确保从 GitSettingsView 返回后显示最新值（修复 Bug 2: 保存后不刷新）
    @State private var gitConfigDisplay: String = "未配置"

    var body: some View {
        settingsList
            .onAppear {
                refreshGitConfigDisplay()
            }
    }

    /// 设置列表 — 显示所有分区入口，使用 NavigationLink 推入子页面
    private var settingsList: some View {
        List {
            // AI 模型配置（合并 API Key + 默认模型）
            NavigationLink(value: SettingsSection.aiModel) {
                SettingsRow(
                    icon: "brain.head.profile.fill",
                    iconColor: Color.baizeAccent,
                    title: "AI 模型配置",
                    subtitle: aiModelSubtitle
                )
            }

            // 权限模式
            NavigationLink(value: SettingsSection.permission) {
                SettingsRow(
                    icon: "shield.fill",
                    iconColor: appState.permissionMode.badgeColor,
                    title: "权限模式",
                    subtitle: appState.permissionMode.displayName
                )
            }

            // 存储与运行时
            NavigationLink(value: SettingsSection.storage) {
                SettingsRow(
                    icon: "internaldrive.fill",
                    iconColor: Color.baizeSuccess,
                    title: "存储与运行时",
                    subtitle: runtimeSubtitle
                )
            }

            // Git 配置
            NavigationLink(value: SettingsSection.gitConfig) {
                SettingsRow(
                    icon: "arrow.triangle.branch.fill",
                    iconColor: Color.baizeAccent,
                    title: "Git 配置",
                    subtitle: gitConfigDisplay
                )
            }

            // R1: 搜索引擎设置
            NavigationLink(value: SettingsSection.searchEngine) {
                SettingsRow(
                    icon: "magnifyingglass",
                    iconColor: Color.baizeAccent,
                    title: "搜索引擎",
                    subtitle: searchEngineSubtitle
                )
            }

            // R1: 记忆管理
            NavigationLink(value: SettingsSection.memory) {
                SettingsRow(
                    icon: "brain.head.profile",
                    iconColor: Color.baizeSuccess,
                    title: "记忆管理",
                    subtitle: "自动提取 \(MemoryExtractor.isAutoExtractionEnabled() ? "已开启" : "已关闭")"
                )
            }

            // R1: 技能管理
            NavigationLink(value: SettingsSection.skills) {
                SettingsRow(
                    icon: "wand.and.stars",
                    iconColor: Color.baizeWarning,
                    title: "技能管理",
                    subtitle: "已安装技能"
                )
            }

            // 配置备份 — TrollStore 重装后自动恢复设置
            NavigationLink(value: SettingsSection.configBackup) {
                SettingsRow(
                    icon: "externaldrive.badge.timemachine",
                    iconColor: Color.baizeAccent,
                    title: "配置备份",
                    subtitle: "重装后自动恢复设置"
                )
            }

            // 关于白泽
            NavigationLink(value: SettingsSection.about) {
                SettingsRow(
                    icon: "info.circle.fill",
                    iconColor: .gray,
                    title: "关于白泽",
                    subtitle: "版本 1.0.0  |  TrollStore ✅  |  iPad Pro M1"
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationDestination(for: SettingsSection.self) { section in
            switch section {
            case .aiModel:
                UnifiedAIConfigView(appState: appState)
            case .permission:
                PermissionSettingsView(appState: appState)
            case .storage:
                StorageSettingsView(appState: appState)
            case .gitConfig:
                GitSettingsView(appState: appState)
            case .searchEngine:
                SearchEngineSettingsView(appState: appState)
            case .memory:
                MemorySettingsView(appState: appState)
            case .skills:
                SkillsManagerView(appState: appState)
            case .configBackup:
                ConfigBackupSettingsView()
            case .about:
                AboutView()
            }
        }
    }

    /// AI 模型配置状态描述（Provider/Model + Key 配置情况）
    /// Bug #14 fix: 复用 appState.keychainService 避免每次访问都创建新实例
    private var aiModelSubtitle: String {
        let keychain = appState.keychainService ?? KeychainService()
        var configured: [String] = []
        if keychain.loadOpenAIKey() != nil { configured.append("OpenAI") }
        if keychain.loadAnthropicKey() != nil { configured.append("Anthropic") }
        if keychain.loadOpenRouterKey() != nil { configured.append("OpenRouter") }
        let keyStatus = configured.isEmpty ? "未配置 Key" : "Key: " + configured.joined(separator: ", ")
        return "\(appState.activeProvider.displayName) / \(appState.activeModel)  |  \(keyStatus)"
    }

    /// 搜索引擎状态描述
    private var searchEngineSubtitle: String {
        let keychain = KeychainService()
        if keychain.load(key: WebSearchFactory.tavilyKeyKeychainKey) != nil { return "Tavily" }
        if keychain.load(key: WebSearchFactory.bingKeyKeychainKey) != nil { return "Bing" }
        if keychain.load(key: WebSearchFactory.googleKeyKeychainKey) != nil { return "Google" }
        return "DuckDuckGo（免 Key）"
    }

    /// 运行时状态描述
    private var runtimeSubtitle: String {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let nodeFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/NodeMobile.framework")
        let nodeFrameworkExists = fm.fileExists(atPath: nodeFrameworkPath)
        let pythonFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/Python.framework")
        let pythonFrameworkExists = fm.fileExists(atPath: pythonFrameworkPath)
        let monacoHtmlExists = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "monaco-editor") != nil
        return "Node \(nodeFrameworkExists ? "✅" : "❌")  Python \(pythonFrameworkExists ? "✅" : "❌")  Monaco \(monacoHtmlExists ? "✅" : "❌")"
    }

    /// 从 UserDefaults 重新读取 Git 配置并更新显示（修复 Bug 2: 保存后不刷新）
    private func refreshGitConfigDisplay() {
        let keychain = KeychainService()
        let hasToken = keychain.hasGitToken()
        let remoteURL = UserDefaults.standard.string(forKey: BaizeGit.remoteURLUDKey) ?? ""
        if hasToken && !remoteURL.isEmpty {
            gitConfigDisplay = "Token ✅  |  \(remoteURL)"
        } else if hasToken {
            gitConfigDisplay = "Token ✅  |  远程 URL 未配置"
        } else {
            gitConfigDisplay = "未配置"
        }
    }
}

// MARK: - Settings Section Enum

/// 设置页面分区
enum SettingsSection: Hashable, Identifiable {
    case aiModel    // merged: API key + model selection
    case permission
    case storage
    case gitConfig
    case searchEngine  // R1: 搜索引擎设置
    case memory        // R1: 记忆管理
    case skills        // R1: 技能管理
    case configBackup  // 配置备份/恢复
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .aiModel: return "AI 模型配置"
        case .permission: return "权限模式"
        case .storage: return "存储与运行时"
        case .gitConfig: return "Git 配置"
        case .searchEngine: return "搜索引擎"
        case .memory: return "记忆管理"
        case .skills: return "技能管理"
        case .configBackup: return "配置备份"
        case .about: return "关于白泽"
        }
    }
}

// MARK: - Settings Row (列表行)

/// 设置列表行 — 纯展示，点击由 NavigationLink 处理
private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Storage Settings View

/// 存储与运行时设置 — 诊断面板
/// 保留 Python 引擎诊断 + Monaco 编辑器诊断（用户只有 iPad 无 Mac）
struct StorageSettingsView: View {
    /// AppState（用于访问 pythonRuntimeEngine 诊断状态）
    let appState: AppState

    /// Python 引擎诊断状态（由 Timer 每 0.5 秒刷新）
    @State private var diagnostic: PythonDiagnosticState = PythonDiagnosticState()

    /// Monaco 编辑器诊断状态（由 Timer 每 0.5 秒刷新）
    @State private var monacoDiagnostic: MonacoDiagnosticState = MonacoDiagnosticState()

    /// Python 引擎状态对应的颜色
    private var statusColor: Color {
        switch diagnostic.status {
        case .started: return Color.baizeSuccess
        case .failed: return Color.baizeError
        case .starting, .notStarted: return Color.baizeWarning
        }
    }

    /// Monaco 编辑器状态对应的颜色
    private var monacoStatusColor: Color {
        switch monacoDiagnostic.status {
        case .loaded: return Color.baizeSuccess
        case .failed: return Color.baizeError
        case .loading: return Color.baizeWarning
        case .notLoaded: return .gray
        }
    }

    var body: some View {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let nodeFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/NodeMobile.framework")
        let nodeFrameworkExists = fm.fileExists(atPath: nodeFrameworkPath)
        let bootstrapPath = Bundle.main.path(forResource: "bootstrap", ofType: "js", inDirectory: "nodejs")
        let bootstrapExists = bootstrapPath != nil
        let pythonFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/Python.framework")
        let pythonFrameworkExists = fm.fileExists(atPath: pythonFrameworkPath)
        let pythonBootstrapPath = Bundle.main.path(forResource: "bootstrap", ofType: "py", inDirectory: "python_scripts")
        let pythonBootstrapExists = pythonBootstrapPath != nil

        Form {
            Section(header: Text("项目目录")) {
                Text(BaizePath.projectRoot)
                    .font(.system(size: 13, design: .monospaced))
            }

            Section(header: Text("Node.js 运行时")) {
                HStack {
                    Text("NodeMobile.framework")
                    Spacer()
                    Text(nodeFrameworkExists ? "✅ 已嵌入" : "❌ 未找到")
                        .foregroundColor(nodeFrameworkExists ? Color.baizeSuccess : Color.baizeError)
                }
                HStack {
                    Text("bootstrap.js")
                    Spacer()
                    Text(bootstrapExists ? "✅ 已找到" : "❌ 未找到")
                        .foregroundColor(bootstrapExists ? Color.baizeSuccess : Color.baizeError)
                }
                if let bsPath = bootstrapPath {
                    Text("路径: \(bsPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("引擎端口: \(BaizeNode.enginePort)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Python 运行时")) {
                HStack {
                    Text("Python.framework")
                    Spacer()
                    Text(pythonFrameworkExists ? "✅ 已嵌入" : "❌ 未找到")
                        .foregroundColor(pythonFrameworkExists ? Color.baizeSuccess : Color.baizeError)
                }
                HStack {
                    Text("bootstrap.py")
                    Spacer()
                    Text(pythonBootstrapExists ? "✅ 已找到" : "❌ 未找到")
                        .foregroundColor(pythonBootstrapExists ? Color.baizeSuccess : Color.baizeError)
                }
                if let pyBsPath = pythonBootstrapPath {
                    Text("路径: \(pyBsPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("引擎端口: \(BaizePython.enginePort)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // P3: Python 引擎诊断面板 — 显示引擎启动状态和错误信息
            // 用户无需 Mac/Console.app 即可在 iPad 上查看引擎诊断
            Section(header: Text("Python 引擎诊断")) {
                // 引擎状态
                HStack {
                    Text("引擎状态")
                    Spacer()
                    Text(diagnostic.status.rawValue)
                        .foregroundColor(statusColor)
                        .fontWeight(.medium)
                }

                // PYTHONHOME 路径
                if let home = diagnostic.pythonHome {
                    Text("PYTHONHOME: \(home)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // PYTHONPATH 路径
                if let path = diagnostic.pythonPath {
                    Text("PYTHONPATH: \(path)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // 最后一条错误信息
                if let err = diagnostic.lastError {
                    Text("错误: \(err)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeError)
                }

                // 启动步骤时间线
                if diagnostic.steps.isEmpty {
                    Text("暂无诊断信息（引擎尚未启动）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                ForEach(diagnostic.steps) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(step.success ? "✅" : "❌")
                            Text(step.step)
                                .font(.system(size: 12))
                            Spacer()
                            Text(step.timestamp, style: .time)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Text(step.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Monaco 编辑器诊断面板 — 显示 WebView 加载状态和资源检查结果
            // 用户无需 Mac/Console.app 即可在 iPad 上查看 Monaco 编辑器诊断
            Section(header: Text("Monaco 编辑器诊断")) {
                // 加载状态
                HStack {
                    Text("加载状态")
                    Spacer()
                    Text(monacoDiagnostic.status.rawValue)
                        .foregroundColor(monacoStatusColor)
                        .fontWeight(.medium)
                }

                // min/vs/loader.js 存在性
                HStack {
                    Text("min/vs/loader.js")
                    Spacer()
                    Text(monacoDiagnostic.loaderExists ? "✅ 存在" : "❌ 缺失")
                        .foregroundColor(monacoDiagnostic.loaderExists ? Color.baizeSuccess : Color.baizeError)
                }

                // 编辑器就绪状态
                HStack {
                    Text("编辑器就绪")
                    Spacer()
                    Text(monacoDiagnostic.editorReady ? "✅ 是" : "❌ 否")
                        .foregroundColor(monacoDiagnostic.editorReady ? Color.baizeSuccess : Color.baizeError)
                }

                // 加载耗时
                if let duration = monacoDiagnostic.loadDurationMs {
                    HStack {
                        Text("加载耗时")
                        Spacer()
                        Text("\(duration) ms")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // 导航完成次数
                HStack {
                    Text("导航完成次数")
                    Spacer()
                    Text("\(monacoDiagnostic.navigationCount)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // index.html 路径
                if let htmlPath = monacoDiagnostic.htmlPath {
                    Text("HTML: \(htmlPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("HTML: ❌ 未找到 index.html")
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeError)
                }

                // 当前选中文件
                if let selected = monacoDiagnostic.selectedFilePath {
                    Text("选中文件: \(selected)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("选中文件: 无")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                // 最后一条错误
                if let err = monacoDiagnostic.lastError {
                    Text("错误: \(err)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeError)
                }

                // 重新加载编辑器按钮
                Button(action: {
                    appState.monacoBridge?.reloadEditor()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("重新加载编辑器")
                    }
                }
                .disabled(appState.monacoBridge == nil)
            }

            Section(header: Text("App Bundle 路径")) {
                Text(bundlePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            diagnostic = appState.pythonRuntimeEngine?.getDiagnostic() ?? PythonDiagnosticState()
            monacoDiagnostic = appState.monacoBridge?.getDiagnostic() ?? MonacoDiagnosticState()
        }
        .navigationTitle("存储与运行时")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            diagnostic = appState.pythonRuntimeEngine?.getDiagnostic() ?? PythonDiagnosticState()
            monacoDiagnostic = appState.monacoBridge?.getDiagnostic() ?? MonacoDiagnosticState()
        }
    }
}

// MARK: - About View

/// 关于白泽页面
struct AboutView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundColor(Color.baizeAccent.opacity(0.4))

            Text("白泽")
                .font(.largeTitle.bold())
                .foregroundColor(Color.baizeAccent)

            Text("iOS 本地编程智能体")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                InfoRow(label: "版本", value: "1.0.0")
                InfoRow(label: "TrollStore", value: "已安装 ✅")
                InfoRow(label: "设备", value: "iPad Pro M1")
                InfoRow(label: "iOS", value: "16.6.1")
                InfoRow(label: "沙箱", value: "已解除 (no-sandbox)")
            }
            .padding(.horizontal, 40)

            Text("像 Claude Code 一样强大，但所有工具执行在本地完成")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .navigationTitle("关于白泽")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 信息行
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Config Backup Settings View

/// 配置备份/恢复设置页 — 手动备份、手动恢复、显示上次备份时间
///
/// 正常情况下配置变更会自动触发节流备份，用户无需手动操作。
/// 此页面提供手动入口作为兜底：
/// - "立即备份配置" — 手动触发完整备份
/// - "从备份恢复配置" — 手动从 config.json 恢复（恢复后需重启 App 生效）
struct ConfigBackupSettingsView: View {
    /// 上次备份时间（从 config.json 读取）
    @State private var lastBackupTime: Date?

    /// 备份中状态
    @State private var isBackingUp = false

    /// 恢复完成提示
    @State private var showRestoreAlert = false

    /// 操作结果消息
    @State private var resultMessage = ""

    var body: some View {
        Form {
            // 备份信息 Section
            Section(
                header: Text("备份状态"),
                footer: Text("备份文件位于 App 容器外（/var/mobile/Documents/Baize/.baize/config.json），TrollStore 重装白泽后设置可自动恢复。")
            ) {
                if let time = lastBackupTime {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.baizeSuccess)
                        Text("上次备份时间")
                        Spacer()
                        Text(time, style: .date)
                            .foregroundColor(.secondary)
                        Text(time, style: .time)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color.baizeWarning)
                        Text("尚未备份")
                            .foregroundColor(.secondary)
                    }
                }

                // 显示备份文件路径
                Text(BaizePath.globalConfig)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 手动操作 Section
            Section(header: Text("手动操作")) {
                // 立即备份
                Button(action: {
                    Task {
                        isBackingUp = true
                        await ConfigBackupService.shared.backupNow()
                        lastBackupTime = await ConfigBackupService.shared.getLastBackupTime()
                        isBackingUp = false
                    }
                }) {
                    HStack {
                        if isBackingUp {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "tray.and.arrow.down.fill")
                        }
                        Text(isBackingUp ? "备份中..." : "立即备份配置")
                    }
                    .foregroundColor(Color.baizeAccent)
                }
                .disabled(isBackingUp)

                // 从备份恢复
                Button(action: {
                    // restoreSync 是同步方法，直接调用
                    ConfigBackupService.restoreSync()
                    resultMessage = "配置已从备份恢复。请重启 App 使所有设置生效。"
                    showRestoreAlert = true
                }) {
                    HStack {
                        Image(systemName: "tray.and.arrow.up.fill")
                        Text("从备份恢复配置")
                    }
                    .foregroundColor(Color.baizeSuccess)
                }
            }

            // 说明 Section
            Section(header: Text("工作原理")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 配置变更时自动备份（5 秒节流，避免频繁写文件）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("2. App 启动时自动从 config.json 恢复（在加载设置之前）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("3. 备份内容包括：AI Provider/Model、自定义端点、API Keys、Git 配置")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("4. API Keys 以明文存储，TrollStore 环境下可接受（设备本地、用户自有）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("配置备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                lastBackupTime = await ConfigBackupService.shared.getLastBackupTime()
            }
        }
        .alert("恢复完成", isPresented: $showRestoreAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(resultMessage)
        }
    }
}
