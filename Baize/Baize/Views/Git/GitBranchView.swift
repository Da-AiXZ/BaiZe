import SwiftUI

/// Git 分支视图（P1）— 分支列表，当前分支高亮，切换/新建分支
struct GitBranchView: View {
    @ObservedObject var viewModel: GitViewModel

    @State private var showCreateBranch: Bool = false
    @State private var newBranchName: String = ""

    // T02: 删除/重命名/合并/变基状态
    @State private var branchToDelete: GitBranch?
    @State private var branchToRename: GitBranch?
    @State private var renameNewName: String = ""
    @State private var branchToMerge: GitBranch?
    @State private var branchToRebase: GitBranch?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 本地分支
                if !viewModel.branches.isEmpty {
                    Text("本地分支")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.baizeTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(viewModel.branches) { branch in
                        branchRow(branch)
                    }
                }

                // 远程分支
                if !viewModel.remoteBranches.isEmpty {
                    Text("远程分支")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.baizeTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    ForEach(viewModel.remoteBranches) { branch in
                        remoteBranchRow(branch)
                    }
                }

                // 空状态
                if viewModel.branches.isEmpty && viewModel.remoteBranches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无分支")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                // 新建分支按钮
                Button(action: {
                    showCreateBranch = true
                    newBranchName = ""
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("新建分支")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(Color.baizeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            if viewModel.branches.isEmpty {
                Task { await viewModel.loadBranches() }
            }
            if viewModel.remoteBranches.isEmpty {
                Task { await viewModel.loadRemoteBranches() }
            }
        }
        .sheet(isPresented: $showCreateBranch) {
            createBranchSheet
        }
        .sheet(isPresented: Binding(
            get: { branchToRename != nil },
            set: { if !$0 { branchToRename = nil; renameNewName = "" } }
        )) {
            renameBranchSheet
        }
        .confirmationDialog(
            "删除分支 \(branchToDelete?.name ?? "")？",
            isPresented: Binding(
                get: { branchToDelete != nil },
                set: { if !$0 { branchToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let branch = branchToDelete {
                    Task { await viewModel.deleteBranch(name: branch.name) }
                    branchToDelete = nil
                }
            }
            Button("取消", role: .cancel) {
                branchToDelete = nil
            }
        } message: {
            Text("此操作不可撤销。不能删除当前所在分支。")
        }
        .confirmationDialog(
            "将 \(branchToMerge?.name ?? "") 合并到当前分支？",
            isPresented: Binding(
                get: { branchToMerge != nil },
                set: { if !$0 { branchToMerge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("合并") {
                if let branch = branchToMerge {
                    Task { await viewModel.merge(branch: branch.name) }
                    branchToMerge = nil
                }
            }
            Button("取消", role: .cancel) {
                branchToMerge = nil
            }
        } message: {
            Text("如果存在冲突，将返回冲突文件列表。")
        }
        .confirmationDialog(
            "将当前分支变基到 \(branchToRebase?.name ?? "")？",
            isPresented: Binding(
                get: { branchToRebase != nil },
                set: { if !$0 { branchToRebase = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("变基") {
                if let branch = branchToRebase {
                    Task { await viewModel.rebase(branch: branch.name) }
                    branchToRebase = nil
                }
            }
            Button("取消", role: .cancel) {
                branchToRebase = nil
            }
        } message: {
            Text("变基会重放当前分支的提交到目标分支之上。如有冲突将中止并返回冲突列表。")
        }
    }

    /// 分支行
    private func branchRow(_ branch: GitBranch) -> some View {
        Button(action: {
            guard !branch.isCurrent else { return }
            Task { await viewModel.checkoutBranch(branch.name) }
        }) {
            HStack(spacing: 10) {
                // 当前分支 checkmark
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(branch.isCurrent ? Color.baizeAccent : Color.baizeTextSecondary)

                // 分支图标
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14))
                    .foregroundColor(branch.isCurrent ? Color.baizeAccent : Color.baizeTextSecondary)

                // 分支名
                Text(branch.name)
                    .font(.system(size: 15, weight: branch.isCurrent ? .semibold : .regular))
                    .foregroundColor(branch.isCurrent ? Color.baizeAccent : Color.baizeTextPrimary)

                Spacer()

                // 当前标签
                if branch.isCurrent {
                    Text("当前")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.baizeAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.baizeAccent.opacity(0.1))
                        .cornerRadius(4)
                }

                // 切换中指示器
                if viewModel.isSwitchingBranch && !branch.isCurrent {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                branch.isCurrent
                    ? Color.baizeAccent.opacity(0.05)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSwitchingBranch)
        // T02: 长按菜单 — 删除/重命名/合并到当前/变基到当前
        // 注：swipeActions 需要 List 上下文，当前使用 ScrollView 故用 contextMenu 替代
        .contextMenu {
            if !branch.isCurrent {
                Button {
                    branchToMerge = branch
                } label: {
                    Label("合并到当前", systemImage: "arrow.merge")
                }

                Button {
                    branchToRebase = branch
                } label: {
                    Label("变基到当前", systemImage: "arrow.uturn.down")
                }
            }

            Button {
                branchToRename = branch
                renameNewName = branch.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            if !branch.isCurrent {
                Button(role: .destructive) {
                    branchToDelete = branch
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    /// 远程分支行（T02 #9）
    private func remoteBranchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 10) {
            // 远程分支图标
            Image(systemName: "icloud")
                .font(.system(size: 14))
                .foregroundColor(Color.baizeTextSecondary)

            // 分支名（含 origin/ 前缀）
            Text(branch.name)
                .font(.system(size: 15))
                .foregroundColor(Color.baizeTextPrimary)

            Spacer()

            // 检出按钮
            Button(action: {
                Task { await viewModel.checkoutRemoteBranch(name: branch.name) }
            }) {
                Text("检出")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.baizeAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.baizeAccent.opacity(0.1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSwitchingBranch)

            if viewModel.isSwitchingBranch {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.baizeCardBackground.opacity(0.2))
    }

    /// 新建分支 Sheet
    private var createBranchSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("新建分支")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    Text("将从当前分支创建新分支并自动切换")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                TextField("分支名（如: feature/new-ui）", text: $newBranchName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(12)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.baizeBorder, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Spacer()

                // 操作按钮
                HStack(spacing: 12) {
                    Button("取消") {
                        showCreateBranch = false
                        newBranchName = ""
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("创建") {
                        Task {
                            await viewModel.createBranch(newBranchName)
                            showCreateBranch = false
                            newBranchName = ""
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.baizeAccent.opacity(0.5)
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium])
    }

    /// 重命名分支 Sheet（T02 #8）
    private var renameBranchSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("重命名分支")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    if let branch = branchToRename {
                        Text("将 '\(branch.name)' 重命名为新名称")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                TextField("新分支名", text: $renameNewName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(12)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.baizeBorder, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Spacer()

                // 操作按钮
                HStack(spacing: 12) {
                    Button("取消") {
                        branchToRename = nil
                        renameNewName = ""
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("重命名") {
                        if let branch = branchToRename {
                            Task {
                                await viewModel.renameBranch(
                                    oldName: branch.name,
                                    newName: renameNewName
                                )
                                branchToRename = nil
                                renameNewName = ""
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.baizeAccent.opacity(0.5)
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                    .disabled(renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium])
    }
}
