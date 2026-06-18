import SwiftUI

/// 设置页完整视图 — 合并 API Key + 模型选择为统一的 AI 模型配置入口
/// 链接到 UnifiedAIConfigView 和 PermissionSettingsView
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedSection: SettingsSection?

    var body: some View {
        NavigationStack {
            List {
                // AI 模型配置（合并 API Key + 默认模型）
                SettingsSectionLink(
                    icon: "brain.head.profile.fill",
                    iconColor: .purple,
                    title: "AI 模型配置",
                    subtitle: aiModelSubtitle,
                    section: .aiModel
                )

                // 权限模式 → 完整的 PermissionSettingsView
                SettingsSectionLink(
                    icon: "shield.fill",
                    iconColor: appState.permissionMode.badgeColor,
                    title: "权限模式",
                    subtitle: appState.permissionMode.displayName,
                    section: .permission
                )

                // 存储与运行时
                SettingsSectionLink(
                    icon: "internaldrive.fill",
                    iconColor: .green,
                    title: "存储与运行时",
                    subtitle: runtimeSubtitle,
                    section: .storage
                )

                // 关于白泽
                SettingsSectionLink(
                    icon: "info.circle.fill",
                    iconColor: .gray,
                    title: "关于白泽",
                    subtitle: "版本 1.0.0  |  TrollStore ✅  |  iPad Pro M1",
                    section: .about
                )
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationDestination(for: SettingsSection.self) { section in
                SettingsDetail(section: section, appState: appState)
            }
        }
    }

    /// AI 模型配置状态描述（Provider/Model + Key 配置情况）
    private var aiModelSubtitle: String {
        let keychain = KeychainService()
        var configured: [String] = []
        if keychain.loadOpenAIKey() != nil { configured.append("OpenAI") }
        if keychain.loadAnthropicKey() != nil { configured.append("Anthropic") }
        if keychain.loadOpenRouterKey() != nil { configured.append("OpenRouter") }
        let keyStatus = configured.isEmpty ? "未配置 Key" : "Key: " + configured.joined(separator: ", ")
        return "\(appState.activeProvider.displayName) / \(appState.activeModel)  |  \(keyStatus)"
    }

    /// 运行时状态描述
    private var runtimeSubtitle: String {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let nodeFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/NodeMobile.framework")
        let nodeFrameworkExists = fm.fileExists(atPath: nodeFrameworkPath)
        let pythonExists = fm.fileExists(atPath: BaizePath.pythonBinary)
        return "Node.js \(nodeFrameworkExists ? "✅" : "❌")  Python \(pythonExists ? "✅" : "❌")"
    }
}

// MARK: - Settings Section Enum

/// 设置页面分区
enum SettingsSection: Hashable, Identifiable {
    case aiModel    // merged: API key + model selection
    case permission
    case storage
    case about

    var id: String { "\(self)" }

    var title: String {
        switch self {
        case .aiModel: return "AI 模型配置"
        case .permission: return "权限模式"
        case .storage: return "存储与运行时"
        case .about: return "关于白泽"
        }
    }
}

// MARK: - Settings Section Link

/// 设置分区导航链接
private struct SettingsSectionLink: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let section: SettingsSection

    var body: some View {
        NavigationLink(value: section) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings Detail

/// 设置详情页 — 集成 UnifiedAIConfigView 和 PermissionSettingsView
private struct SettingsDetail: View {
    let section: SettingsSection
    @ObservedObject var appState: AppState

    var body: some View {
        switch section {
        case .aiModel:
            UnifiedAIConfigView(appState: appState)

        case .permission:
            PermissionSettingsView(appState: appState)

        case .storage:
            StorageSettingsPlaceholder()

        case .about:
            AboutView()
        }
    }
}

// MARK: - Storage Settings Placeholder

/// 存储与运行时设置占位
private struct StorageSettingsPlaceholder: View {
    var body: some View {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let nodeFrameworkPath = (bundlePath as NSString).appendingPathComponent("Frameworks/NodeMobile.framework")
        let nodeFrameworkExists = fm.fileExists(atPath: nodeFrameworkPath)
        let bootstrapPath = Bundle.main.path(forResource: "bootstrap", ofType: "js", inDirectory: "nodejs")
        let bootstrapExists = bootstrapPath != nil
        let pythonExists = fm.fileExists(atPath: BaizePath.pythonBinary)

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
                        .foregroundColor(nodeFrameworkExists ? .green : .red)
                }
                HStack {
                    Text("bootstrap.js")
                    Spacer()
                    Text(bootstrapExists ? "✅ 已找到" : "❌ 未找到")
                        .foregroundColor(bootstrapExists ? .green : .red)
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
                    Text("Python")
                    Spacer()
                    Text(pythonExists ? "✅ 可用" : "❌ 不可用 (placeholder)")
                        .foregroundColor(pythonExists ? .green : .red)
                }
            }

            Section(header: Text("App Bundle 路径")) {
                Text(bundlePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("存储与运行时")
    }
}

// MARK: - About View

/// 关于白泽页面
private struct AboutView: View {
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