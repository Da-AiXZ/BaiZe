import SwiftUI

/// Git Tab 主视图 — NavigationStack + 3 section（Modified/Staged/Untracked）+ commit 输入 + 底部子 Tab
struct GitStatusView: View {
    @ObservedObject var viewModel: GitViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 非仓库空状态 — 显示初始化按钮而非报错 Alert
            if viewModel.isNotAGitRepository {
                notAGitRepositoryView
            } else {
                // 主内容区 — 根据子 Tab 切换
                GitSubTabView(viewModel: viewModel)
            }
        }
        .navigationTitle("Git")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // 推送按钮
                Button(action: {
                    Task { await viewModel.push() }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        // Bug fix (P0): 未配置 Token 时用黄色警告色，给用户视觉提示
                        .foregroundColor(viewModel.hasGitToken ? Color.baizeAccent : Color.baizeWarning)
                }
                // Bug fix (P0): 未配置 Token 时直接禁用按钮，避免点击后 guard 失败却无反馈
                .disabled(viewModel.isPushing || viewModel.isNotAGitRepository || !viewModel.hasGitToken)
                .help(viewModel.hasGitToken ? "推送到远程仓库" : "未配置 GitHub Token，请在设置中配置")

                if viewModel.isPushing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .overlay(alignment: .top) {
            if viewModel.showSuccess, let msg = viewModel.successMessage {
                Text(msg)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.baizeSuccess)
                    .cornerRadius(10)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            Task { await viewModel.refreshStatus() }
        }
    }

    /// 非 Git 仓库空状态 — 引导用户初始化仓库
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

            // 提示：配置 Token 后可以推送
            if !viewModel.hasGitToken {
                Text("提示：初始化后可在设置中配置 GitHub Token 以推送代码")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeChatBackground)
    }
}

// MARK: - Changes Section View

/// 改动视图 — 显示 modified/staged/untracked 三个 section + commit 输入
struct GitChangesView: View {
    @ObservedObject var viewModel: GitViewModel

    var body: some View {
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

                // 加载中
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
                    // 已暂存改动 Section
                    if !status.staged.isEmpty {
                        changesSection(
                            title: "已暂存的改动",
                            icon: "checkmark.circle.fill",
                            iconColor: Color.baizeSuccess,
                            files: status.staged,
                            actionIcon: "minus.circle",
                            actionColor: Color.baizeError,
                            action: { path in
                                Task { await viewModel.unstageFile(path) }
                            }
                        )
                    }

                    // 未暂存改动 Section
                    if !status.modified.isEmpty {
                        changesSection(
                            title: "未暂存的改动",
                            icon: "pencil.circle.fill",
                            iconColor: Color.baizeWarning,
                            files: status.modified,
                            actionIcon: "plus.circle",
                            actionColor: Color.baizeSuccess,
                            action: { path in
                                Task { await viewModel.stageFile(path) }
                            }
                        )
                    }

                    // 未追踪文件 Section
                    if !status.untracked.isEmpty {
                        changesSection(
                            title: "未追踪文件",
                            icon: "questionmark.circle.fill",
                            iconColor: Color.baizeTextSecondary,
                            files: status.untracked,
                            actionIcon: "plus.circle",
                            actionColor: Color.baizeSuccess,
                            action: { path in
                                Task { await viewModel.stageFile(path) }
                            }
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

                    // 全部暂存/取消暂存按钮
                    if status.hasChanges {
                        HStack(spacing: 12) {
                            Button(action: {
                                Task { await viewModel.stageAll() }
                            }) {
                                Text("全部暂存")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.baizeAccent)
                                    .cornerRadius(8)
                            }

                            Button(action: {
                                Task { await viewModel.unstageAll() }
                            }) {
                                Text("全部取消暂存")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color.baizeAccent)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.baizeCardBackground)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.baizeAccent, lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }

                    // Commit 输入区
                    if status.hasStagedChanges || viewModel.isCommitting {
                        commitInputArea
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// 文件变更 Section
    private func changesSection(
        title: String,
        icon: String,
        iconColor: Color,
        files: [GitFileStatus],
        actionIcon: String,
        actionColor: Color,
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section 标题
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

            // 文件列表
            ForEach(files) { file in
                fileRow(file: file, actionIcon: actionIcon, actionColor: actionColor, action: action)
            }
        }
    }

    /// 单个文件行
    private func fileRow(
        file: GitFileStatus,
        actionIcon: String,
        actionColor: Color,
        action: @escaping (String) -> Void
    ) -> some View {
        // Bug fix (P0): Button 不能嵌套在 NavigationLink 的 label 闭包内，
        // 否则 NavigationLink 会拦截 Button 的点击事件，导致暂存/取消暂存按钮"无反应"。
        // 修复：将 Button 移出 NavigationLink，作为 HStack 同级子视图独立响应点击。
        HStack(spacing: 10) {
            // 文件信息部分 — 点击跳转 diff 视图
            NavigationLink(
                destination: GitDiffView(
                    viewModel: viewModel,
                    filePath: file.path,
                    diffType: file.isStaged ? .indexVsHead : .workingTreeVsIndex
                )
            ) {
                HStack(spacing: 10) {
                    // 状态标识
                    Text(file.changeStatus.icon)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(file.changeStatus.color)
                        .frame(width: 24, alignment: .center)

                    // 文件名
                    Text(file.displayName)
                        .font(.system(size: 14))
                        .foregroundColor(Color.baizeTextPrimary)
                        .lineLimit(1)

                    // 文件路径（相对路径的目录部分）
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

            // 操作按钮 — 独立点击，不被 NavigationLink 拦截
            Button(action: {
                action(file.path)
            }) {
                Image(systemName: actionIcon)
                    .font(.system(size: 18))
                    .foregroundColor(actionColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground.opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
    }

    /// Commit 消息输入区
    private var commitInputArea: some View {
        VStack(spacing: 8) {
            TextField("提交消息", text: $viewModel.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(12)
                .background(Color.baizeCardBackground)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.baizeBorder, lineWidth: 1)
                )
                .padding(.horizontal, 16)

            Button(action: {
                Task { await viewModel.commit() }
            }) {
                HStack {
                    if viewModel.isCommitting {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                    }
                    Text("提交")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.baizeAccent.opacity(0.5)
                        : Color.baizeAccent
                )
                .cornerRadius(10)
            }
            .disabled(
                viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || viewModel.isCommitting
            )
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
    }
}
