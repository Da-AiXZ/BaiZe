import SwiftUI

/// 项目首页 Dashboard — 独立 Tab，蓝白极简风格
/// 显示最近项目、API 连接状态（真实 Keychain 数据）、今日用量
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var recentProjects: [ProjectEntry] = ProjectEntry.mockProjects

    private let keychain = KeychainService()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 标题栏
                DashboardHeader()

                Divider()
                    .background(Color.baizeBorder)

                // 最近项目
                RecentProjectsSection(projects: recentProjects)

                Divider()
                    .background(Color.baizeBorder)

                // 连接状态（使用真实 Keychain 数据）
                ConnectionStatusSection(
                    openAIConfigured: keychain.loadOpenAIKey() != nil,
                    anthropicConfigured: keychain.loadAnthropicKey() != nil,
                    openRouterConfigured: keychain.loadOpenRouterKey() != nil
                )

                Divider()
                    .background(Color.baizeBorder)

                // 今日用量
                DailyUsageSection()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.baizeBackground)
        .navigationTitle("白泽")
    }
}

// MARK: - Dashboard Header

/// Dashboard 标题栏 — 蓝白极简
private struct DashboardHeader: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("白泽")
                    .font(.largeTitle.bold())
                    .foregroundColor(Color.baizeAccent)

                Text("本地编程智能体")
                    .font(.subheadline)
                    .foregroundColor(Color.baizeTextSecondary)
            }

            Spacer()
        }
    }
}

// MARK: - Recent Projects Section

/// 最近项目网格
private struct RecentProjectsSection: View {
    let projects: [ProjectEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "folder.fill", title: "最近项目")

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                ForEach(projects) { project in
                    ProjectCard(project: project)
                }
            }
        }
    }
}

// MARK: - Project Card

/// 单个项目卡片 — 蓝白极简
private struct ProjectCard: View {
    let project: ProjectEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 项目图标
            Image(systemName: project.icon)
                .font(.system(size: 24))
                .foregroundColor(project.iconColor)

            // 项目名
            Text(project.name)
                .font(.headline)
                .foregroundColor(Color.baizeTextPrimary)
                .lineLimit(1)

            // 技术栈
            Text(project.stack)
                .font(.caption)
                .foregroundColor(Color.baizeTextSecondary)

            // 时间
            Text(project.lastOpened.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(Color.baizeTextSecondary.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.baizeCardBackground)
        .cornerRadius(10)
    }
}

// MARK: - Connection Status Section

/// API 连接状态 — 使用真实 Keychain 数据（从工具栏移入）
private struct ConnectionStatusSection: View {
    let openAIConfigured: Bool
    let anthropicConfigured: Bool
    let openRouterConfigured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "wifi", title: "连接状态")

            HStack(spacing: 16) {
                ConnectionBadge(name: "OpenAI", isConnected: openAIConfigured)
                ConnectionBadge(name: "Anthropic", isConnected: anthropicConfigured)
                ConnectionBadge(name: "OpenRouter", isConnected: openRouterConfigured)
            }
        }
    }
}

/// 单个连接状态徽章
private struct ConnectionBadge: View {
    let name: String
    let isConnected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(isConnected ? Color.baizeSuccess : Color.baizeError.opacity(0.7))

            Text(name)
                .font(.caption)
                .foregroundColor(Color.baizeTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground)
        .cornerRadius(8)
    }
}

// MARK: - Daily Usage Section

/// 今日用量统计
private struct DailyUsageSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "chart.bar.fill", title: "今日用量")

            HStack(spacing: 20) {
                UsageStatItem(label: "Token", value: "0", unit: "K")
                UsageStatItem(label: "API 调用", value: "0", unit: "次")
                UsageStatItem(label: "费用", value: "$0.00", unit: "")
            }
        }
    }
}

/// 单个用量统计项
private struct UsageStatItem: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value + unit)
                .font(.title3.bold())
                .foregroundColor(Color.baizeTextPrimary)

            Text(label)
                .font(.caption)
                .foregroundColor(Color.baizeTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground)
        .cornerRadius(8)
    }
}

// MARK: - Section Header

/// 通用 Section 标题
private struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(Color.baizeAccent)
            Text(title)
                .font(.headline)
                .foregroundColor(Color.baizeTextPrimary)
        }
    }
}

// MARK: - Project Entry Model

/// 项目入口数据模型
struct ProjectEntry: Identifiable {
    let id = UUID()
    let name: String
    let stack: String
    let icon: String
    let iconColor: Color
    let lastOpened: Date

    static let mockProjects: [ProjectEntry] = [
        ProjectEntry(name: "my-app", stack: "React + TypeScript", icon: "globe", iconColor: Color.baizePrimaryLight, lastOpened: Date().addingTimeInterval(-120)),
        ProjectEntry(name: "baize-core", stack: "Swift + SwiftUI", icon: "swift", iconColor: Color.baizeWarning, lastOpened: Date().addingTimeInterval(-3600)),
        ProjectEntry(name: "data-pipeline", stack: "Python + pandas", icon: "chart.bar.fill", iconColor: Color.baizeAccent, lastOpened: Date().addingTimeInterval(-86400)),
    ]
}

// MARK: - New Project Placeholder Sheet

/// 新建项目弹窗占位 — Phase 1
/// 保留定义但不在 Dashboard 中弹出（可从工具栏触发）
struct NewProjectPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(Color.baizeAccent.opacity(0.4))

                Text("新建项目")
                    .font(.title2)
                    .foregroundColor(Color.baizeTextPrimary)

                Text("完整项目创建流程将在后续版本实现")
                    .font(.body)
                    .foregroundColor(Color.baizeTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
