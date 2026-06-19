import SwiftUI

/// Git 分支视图（P1）— 分支列表，当前分支高亮，切换/新建分支
struct GitBranchView: View {
    @ObservedObject var viewModel: GitViewModel

    @State private var showCreateBranch: Bool = false
    @State private var newBranchName: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.branches.isEmpty {
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
                } else {
                    ForEach(viewModel.branches) { branch in
                        branchRow(branch)
                    }
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
        }
        .sheet(isPresented: $showCreateBranch) {
            createBranchSheet
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
}
