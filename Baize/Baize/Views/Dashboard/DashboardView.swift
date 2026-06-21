import SwiftUI

/// 项目首页 Dashboard — 独立 Tab，蓝白极简风格
/// T04: 显示真实项目列表（ProjectRegistry）+ 真实用量（UsageTracker）+ 新建项目入口
/// 显示最近项目、API 连接状态（真实 Keychain 数据）、今日用量
struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    /// T04: 真实项目列表（从 ProjectRegistry async 加载，替代 mockProjects）
    @State private var recentProjects: [ProjectEntry] = []
    /// T04: 今日用量汇总（从 UsageTracker async 加载）
    @State private var todaySummary: UsageSummary?
    /// T04: 新建项目向导 sheet
    @State private var showNewProjectWizard = false

    private let keychain = KeychainService()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 标题栏
                DashboardHeader()

                Divider()
                    .background(Color.baizeBorder)

                // T04: 最近项目（真实数据 + 新建入口 + 点击切换 + 当前高亮）
                RecentProjectsSection(
                    projects: recentProjects,
                    currentProjectPath: appState.currentProjectPath,
                    onSwitchProject: { project in
                        Task { await appState.switchProject(to: project.path) }
                    },
                    onNewProject: { showNewProjectWizard = true },
                    onRemoveProject: { project in
                        Task {
                            await appState.projectRegistry?.remove(id: project.id)
                            await loadProjects()
                        }
                    }
                )

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

                // T04: 今日用量（真实 UsageTracker 数据）
                DailyUsageSection(summary: todaySummary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.baizeBackground)
        .navigationTitle("白泽")
        // T04: 首次加载真实项目列表 + 今日用量
        .onAppear {
            Task {
                await loadProjects()
                await loadUsage()
            }
        }
        // T04: 切换项目后刷新列表（lastOpened 已更新）
        .onChange(of: appState.currentProjectPath) { _ in
            Task {
                await loadProjects()
                await loadUsage()
            }
        }
        // T04: 新建项目向导
        .sheet(isPresented: $showNewProjectWizard) {
            NewProjectWizard(appState: appState)
        }
    }

    // MARK: - T04 Data Loading

    /// T04: 从 ProjectRegistry 加载真实项目列表（按 lastOpened 降序）
    private func loadProjects() async {
        if let registry = appState.projectRegistry {
            let projects = await registry.list()
            await MainActor.run { self.recentProjects = projects }
        }
    }

    /// T04: 从 UsageTracker 加载今日用量汇总
    private func loadUsage() async {
        if let tracker = appState.usageTracker {
            let summary = await tracker.getTodaySummary()
            await MainActor.run { self.todaySummary = summary }
        }
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

/// 最近项目网格 — T04: 真实数据 + 新建入口 + 点击切换 + 当前高亮 + 长按移除
private struct RecentProjectsSection: View {
    let projects: [ProjectEntry]
    let currentProjectPath: String
    let onSwitchProject: (ProjectEntry) -> Void
    let onNewProject: () -> Void
    let onRemoveProject: (ProjectEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(icon: "folder.fill", title: "最近项目")
                Spacer()
                // T04: 新建项目按钮
                Button(action: onNewProject) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("新建项目")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(Color.baizeAccent)
                }
                .buttonStyle(.plain)
            }

            if projects.isEmpty {
                // 空状态
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("暂无项目")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("点击「新建项目」创建第一个项目")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    ForEach(projects) { project in
                        ProjectCard(
                            project: project,
                            isCurrent: project.path == currentProjectPath
                        )
                        .onTapGesture {
                            onSwitchProject(project)
                        }
                        // T04: 长按 → 从注册表移除（不删文件）
                        .contextMenu {
                            Button(role: .destructive) {
                                onRemoveProject(project)
                            } label: {
                                Label("从列表移除", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Project Card

/// 单个项目卡片 — 蓝白极简
/// T04: 增加 isCurrent 高亮 + 点击切换
private struct ProjectCard: View {
    let project: ProjectEntry
    /// T04: 是否为当前活跃项目（高亮显示）
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 项目图标
                Image(systemName: project.icon)
                    .font(.system(size: 24))
                    .foregroundColor(project.iconColor)

                Spacer()

                // T04: 当前项目标记
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color.baizeSuccess)
                }
            }

            // 项目名
            Text(project.name)
                .font(.headline)
                .foregroundColor(Color.baizeTextPrimary)
                .lineLimit(1)

            // 技术栈
            Text(project.stack)
                .font(.caption)
                .foregroundColor(Color.baizeTextSecondary)
                .lineLimit(1)

            // 时间
            Text(project.lastOpened.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(Color.baizeTextSecondary.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // T04: 当前项目用强调色背景 + 边框
        .background(isCurrent ? Color.baizeAccent.opacity(0.08) : Color.baizeCardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.baizeAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
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

/// 今日用量统计 — T04: 真实 UsageTracker 数据
private struct DailyUsageSection: View {
    /// T04: 今日用量汇总（nil 时显示 0）
    let summary: UsageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "chart.bar.fill", title: "今日用量")

            HStack(spacing: 20) {
                UsageStatItem(label: "Token", value: tokenValue, unit: "")
                UsageStatItem(label: "API 调用", value: callCountValue, unit: "次")
                UsageStatItem(label: "费用", value: costValue, unit: "")
            }
        }
    }

    /// Token 数（>=1000 显示 K 单位）
    private var tokenValue: String {
        let tokens = summary?.totalTokens ?? 0
        if tokens >= 1000 {
            return String(format: "%.1fK", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }

    /// API 调用次数
    private var callCountValue: String {
        "\(summary?.apiCallCount ?? 0)"
    }

    /// 估算费用（美元，保留 4 位小数）
    private var costValue: String {
        String(format: "$%.4f", summary?.totalCost ?? 0)
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
// ProjectEntry 已迁移至 Baize/Baize/Services/ProjectRegistry.swift
// （Codable + computed iconColor，支持持久化）

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
