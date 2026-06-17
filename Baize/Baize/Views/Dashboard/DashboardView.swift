import SwiftUI

/// 项目首页 Dashboard — 显示最近项目、连接状态、今日用量
struct DashboardView: View {
    @State private var recentProjects: [ProjectEntry] = ProjectEntry.mockProjects
    @State private var isShowingNewProject = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 标题栏 + 新建项目按钮
                DashboardHeader(onNewProject: { isShowingNewProject = true })

                // 最近项目
                RecentProjectsSection(projects: recentProjects)

                // 连接状态
                ConnectionStatusSection()

                // 今日用量
                DailyUsageSection()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.baizeBackground)
        .navigationTitle("白泽")
        .sheet(isPresented: $isShowingNewProject) {
            NewProjectPlaceholderSheet()
        }
    }
}

// MARK: - Dashboard Header

/// Dashboard 标题栏
private struct DashboardHeader: View {
    let onNewProject: () -> Void

    var body: some View {
        HStack {
            Text("白泽")
                .font(.largeTitle.bold())
                .foregroundColor(Color.baizeAccent)

            Text("本地编程智能体")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onNewProject) {
                Label("新建项目", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundColor(Color.baizeAccent)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.baizeAccent.opacity(0.2))
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

/// 单个项目卡片
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
                .lineLimit(1)

            // 技术栈
            Text(project.stack)
                .font(.caption)
                .foregroundColor(.secondary)

            // 时间
            Text(project.lastOpened.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.baizeCardBackground)
        .cornerRadius(10)
    }
}

// MARK: - Connection Status Section

/// API 连接状态
private struct ConnectionStatusSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "wifi", title: "连接状态")

            HStack(spacing: 16) {
                ConnectionBadge(name: "OpenAI", isConnected: true)
                ConnectionBadge(name: "Anthropic", isConnected: false)
                ConnectionBadge(name: "OpenRouter", isConnected: false)
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
                .foregroundColor(isConnected ? .green : .red.opacity(0.7))

            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
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
                .foregroundColor(.primary)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
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
        ProjectEntry(name: "my-app", stack: "React + TypeScript", icon: "globe", iconColor: .cyan, lastOpened: Date().addingTimeInterval(-120)),
        ProjectEntry(name: "baize-core", stack: "Swift + SwiftUI", icon: "swift", iconColor: .orange, lastOpened: Date().addingTimeInterval(-3600)),
        ProjectEntry(name: "data-pipeline", stack: "Python + pandas", icon: "chart.bar.fill", iconColor: .blue, lastOpened: Date().addingTimeInterval(-86400)),
    ]
}

// MARK: - New Project Placeholder Sheet

/// 新建项目弹窗占位 — Phase 1
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

                Text("完整项目创建流程将在后续版本实现")
                    .font(.body)
                    .foregroundColor(.secondary)
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