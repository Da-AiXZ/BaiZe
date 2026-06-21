import SwiftUI

/// Git 状态视图 — R3 重构为只读展示（移除 stage/commit 按钮）
/// 改动操作通过 AI 对话 + 工具执行，不再在 UI 手动操作
struct GitStatusView: View {
    @ObservedObject var viewModel: GitViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isNotAGitRepository {
                notAGitRepositoryView
            } else {
                changesList
            }
        }
        .navigationTitle("Git")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await viewModel.refreshStatus() }
        }
    }

    /// 非 Git 仓库空状态
    private var notAGitRepositoryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56))
                .foregroundColor(Color.baizeAccent.opacity(0.6))

            VStack(spacing: 8) {
                Text("当前目录不是 Git 仓库")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("初始化仓库以开始版本管理")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                Task { await viewModel.initRepository() }
            }) {
                HStack(spacing: 8) {
                    if viewModel.isInitializing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 16))
                    }
                    Text(viewModel.isInitializing ? "初始化中..." : "初始化仓库")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.baizeAccent)
                .cornerRadius(12)
            }
            .disabled(viewModel.isInitializing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeChatBackground)
    }

    /// 改动列表（只读展示）
    private var changesList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 当前分支名
                if !viewModel.currentBranch.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 13))
                            .foregroundColor(Color.baizeAccent)
                        Text(viewModel.currentBranch)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.baizeAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if viewModel.isLoading && viewModel.status == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("加载中...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if let status = viewModel.status {
                    // 已暂存改动
                    if !status.staged.isEmpty {
                        changesSection(
                            title: "已暂存的改动",
                            icon: "checkmark.circle.fill",
                            iconColor: Color.baizeSuccess,
                            files: status.staged
                        )
                    }

                    // 未暂存改动
                    if !status.modified.isEmpty {
                        changesSection(
                            title: "未暂存的改动",
                            icon: "pencil.circle.fill",
                            iconColor: Color.baizeWarning,
                            files: status.modified
                        )
                    }

                    // 未追踪文件
                    if !status.untracked.isEmpty {
                        changesSection(
                            title: "未追踪文件",
                            icon: "questionmark.circle.fill",
                            iconColor: Color.baizeTextSecondary,
                            files: status.untracked
                        )
                    }

                    // 空状态
                    if !status.hasChanges {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 48))
                                .foregroundColor(Color.baizeSuccess)
                            Text("工作区干净")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("没有未提交的改动")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// 文件变更 Section（只读，无操作按钮）
    private func changesSection(
        title: String,
        icon: String,
        iconColor: Color,
        files: [GitFileStatus]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(files.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ForEach(files) { file in
                NavigationLink(
                    destination: GitDiffView(
                        viewModel: viewModel,
                        filePath: file.path,
                        diffType: file.isStaged ? .indexVsHead : .workingTreeVsIndex
                    )
                ) {
                    HStack(spacing: 10) {
                        Text(file.changeStatus.icon)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(file.changeStatus.color)
                            .frame(width: 24, alignment: .center)

                        Text(file.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(Color.baizeTextPrimary)
                            .lineLimit(1)

                        let dirPath = (file.path as NSString).deletingLastPathComponent
                        if !dirPath.isEmpty {
                            Text(dirPath)
                                .font(.system(size: 11))
                                .foregroundColor(Color.baizeTextSecondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.baizeCardBackground.opacity(0.5))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
    }
}
