import SwiftUI

/// 设置页完整视图 — T05 集成实际的 API 配置和权限模式设置
/// 链接到 APIKeySettingsView 和 PermissionSettingsView（不再使用占位）
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedSection: SettingsSection?

    var body: some View {
        NavigationStack {
            List {
                // API 配置 → 完整的 APIKeySettingsView
                SettingsSectionLink(
                    icon: "key.fill",
                    iconColor: .yellow,
                    title: "API 配置",
                    subtitle: apiKeySubtitle,
                    section: .apiKey
                )

                // 权限模式 → 完整的 PermissionSettingsView
                SettingsSectionLink(
                    icon: "shield.fill",
                    iconColor: appState.permissionMode.badgeColor,
                    title: "权限模式",
                    subtitle: appState.permissionMode.displayName,
                    section: .permission
                )

                // 默认模型
                SettingsSectionLink(
                    icon: "cpu",
                    iconColor: .purple,
                    title: "默认模型",
                    subtitle: "当前: \(appState.activeProvider.displayName) / \(appState.activeModel)",
                    section: .model
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
            .navigationDestination(item: $selectedSection) { section in
                SettingsDetail(section: section, appState: appState)
            }
        }
    }

    /// API Key 状态描述
    private var apiKeySubtitle: String {
        let keychain = KeychainService()
        var configured: [String] = []
        if keychain.loadOpenAIKey() != nil { configured.append("OpenAI") }
        if keychain.loadAnthropicKey() != nil { configured.append("Anthropic") }
        if keychain.loadOpenRouterKey() != nil { configured.append("OpenRouter") }

        if configured.isEmpty { return "未配置任何 API Key" }
        return "已配置: " + configured.joined(separator: ", ")
    }

    /// 运行时状态描述
    private var runtimeSubtitle: String {
        let fm = FileManager.default
        let nodeExists = fm.fileExists(atPath: BaizePath.nodeBinary)
        let pythonExists = fm.fileExists(atPath: BaizePath.pythonBinary)
        return "Node.js \(nodeExists ? "✅" : "❌")  Python \(pythonExists ? "✅" : "❌")"
    }
}

// MARK: - Settings Section Enum

/// 设置页面分区
enum SettingsSection: Hashable, Identifiable {
    case apiKey
    case permission
    case model
    case storage
    case about

    var id: String { "\(self)" }

    var title: String {
        switch self {
        case .apiKey: return "API 配置"
        case .permission: return "权限模式"
        case .model: return "默认模型"
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

// MARK: - Settings Detail (T05: 集成实际设置视图)

/// 设置详情页 — T05 集成 APIKeySettingsView 和 PermissionSettingsView
private struct SettingsDetail: View {
    let section: SettingsSection
    @ObservedObject var appState: AppState

    var body: some View {
        switch section {
        case .apiKey:
            APIKeySettingsView()

        case .permission:
            PermissionSettingsView(appState: appState)

        case .model:
            ModelSettingsView(appState: appState)

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
        Form {
            Section(header: Text("项目目录")) {
                Text(BaizePath.projectRoot)
                    .font(.system(size: 13, design: .monospaced))
            }

            Section(header: Text("运行时状态")) {
                HStack {
                    Text("Node.js")
                    Spacer()
                    Text(FileManager.default.fileExists(atPath: BaizePath.nodeBinary) ? "可用" : "不可用")
                        .foregroundColor(FileManager.default.fileExists(atPath: BaizePath.nodeBinary) ? .green : .red)
                }
                HStack {
                    Text("Python")
                    Spacer()
                    Text(FileManager.default.fileExists(atPath: BaizePath.pythonBinary) ? "可用" : "不可用")
                        .foregroundColor(FileManager.default.fileExists(atPath: BaizePath.pythonBinary) ? .green : .red)
                }
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