import SwiftUI

/// Git 底部子 Tab 容器 — 改动/历史/分支 切换
struct GitSubTabView: View {
    @ObservedObject var viewModel: GitViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 主内容区
            switch viewModel.selectedSubTab {
            case .changes:
                GitChangesView(viewModel: viewModel)
            case .history:
                GitLogView(viewModel: viewModel)
            case .branches:
                GitBranchView(viewModel: viewModel)
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

    /// 子 Tab 按钮
    private func subTabButton(_ tab: GitSubTab) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.selectedSubTab = tab
            }

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
