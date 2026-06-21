import SwiftUI

/// Git 底部子 Tab 容器 — 改动/历史/分支 切换
struct GitSubTabView: View {
    @ObservedObject var viewModel: GitViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 子 Tab 顶部操作栏（上下文敏感）
            topActionBar

            // 主内容区
            switch viewModel.selectedSubTab {
            case .changes:
                GitChangesView(viewModel: viewModel)
            case .history:
                GitLogView(viewModel: viewModel)
            case .branches:
                GitBranchView(viewModel: viewModel)
            case .stash:
                GitStashView(viewModel: viewModel)
            }

            // 底部子 Tab 栏
            HStack(spacing: 0) {
                ForEach(GitSubTab.allCases, id: \.self) { tab in
                    subTabButton(tab)
                }
            }
            .background(Color.baizeTabBarBackground)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.baizeBorder),
                alignment: .top
            )
        }
    }

    /// 子 Tab 顶部操作栏 — 根据当前子 Tab 显示不同的操作按钮
    @ViewBuilder
    private var topActionBar: some View {
        switch viewModel.selectedSubTab {
        case .changes:
            HStack(spacing: 16) {
                Spacer()
                // Pull 按钮
                Button(action: {
                    Task { await viewModel.pull() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                        Text("Pull")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(viewModel.hasGitToken ? Color.baizeAccent : Color.baizeWarning)
                }
                .disabled(viewModel.isPulling || !viewModel.hasGitToken)
                .buttonStyle(.plain)

                if viewModel.isPulling {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                // Push 按钮（与主工具栏的 Push 按钮并排）
                Button(action: {
                    Task { await viewModel.push() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 14))
                        Text("Push")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(viewModel.hasGitToken ? Color.baizeAccent : Color.baizeWarning)
                }
                .disabled(viewModel.isPushing || !viewModel.hasGitToken)
                .buttonStyle(.plain)

                if viewModel.isPushing {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.baizeCardBackground)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.baizeBorder),
                alignment: .bottom
            )

        case .branches:
            HStack(spacing: 16) {
                Spacer()
                // Fetch 按钮
                Button(action: {
                    Task { await viewModel.fetch() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                        Text("Fetch")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(viewModel.hasGitToken ? Color.baizeAccent : Color.baizeWarning)
                }
                .disabled(viewModel.isFetching || !viewModel.hasGitToken)
                .buttonStyle(.plain)

                if viewModel.isFetching {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.baizeCardBackground)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.baizeBorder),
                alignment: .bottom
            )

        case .history:
            EmptyView()

        case .stash:
            EmptyView()
        }
    }

    /// 子 Tab 按钮
    private func subTabButton(_ tab: GitSubTab) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.selectedSubTab = tab
            }

            // Bug fix (P2): 如果正在加载/推送/提交，跳过重复的数据加载请求。
            // 避免快速连续点击产生竞态导致多个 Task 排队在 GitService actor 上，
            // UI 状态更新延迟，用户感觉"点了没反应"。
            guard !viewModel.isLoading && !viewModel.isPushing && !viewModel.isCommitting else { return }

            // 切换时加载数据
            Task {
                switch tab {
                case .changes:
                    await viewModel.refreshStatus()
                case .history:
                    if viewModel.commits.isEmpty {
                        await viewModel.loadLog()
                    }
                case .branches:
                    if viewModel.branches.isEmpty {
                        await viewModel.loadBranches()
                    }
                case .stash:
                    if viewModel.stashList.isEmpty {
                        await viewModel.loadStashList()
                    }
                }
            }
        }) {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18))
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(
                viewModel.selectedSubTab == tab
                    ? Color.baizeAccent
                    : Color.baizeTextSecondary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                viewModel.selectedSubTab == tab
                    ? Color.baizeTabActive.opacity(0.5)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }
}
