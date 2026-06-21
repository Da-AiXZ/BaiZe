import SwiftUI

/// Git 提交历史视图 — commit 列表，短 hash/作者/相对时间/message
struct GitLogView: View {
    @ObservedObject var viewModel: GitViewModel
    @State private var expandedCommit: GitCommit.ID?

    // T02: 重置/标签状态
    @State private var commitToReset: GitCommit?
    @State private var showResetSheet: Bool = false
    @State private var selectedResetMode: GitResetMode = .mixed
    @State private var commitForTag: GitCommit?
    @State private var showCreateTagSheet: Bool = false
    @State private var tagAtCommitName: String = ""
    @State private var tagAtCommitMessage: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.commits.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无提交历史")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.commits) { commit in
                        commitRow(commit)
                    }

                    // 加载更多按钮
                    if viewModel.hasMoreCommits {
                        Button(action: {
                            Task { await viewModel.loadMoreLog() }
                        }) {
                            HStack {
                                Text("加载更多")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(Color.baizeAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            if viewModel.commits.isEmpty {
                Task { await viewModel.loadLog() }
            }
            // T02: 加载标签列表用于显示 tag 徽章
            if viewModel.tags.isEmpty {
                Task { await viewModel.loadTags() }
            }
        }
        // T02: 重置确认 Sheet
        .sheet(isPresented: $showResetSheet) {
            resetSheet
        }
        // T02: 在指定 commit 创建标签 Sheet
        .sheet(isPresented: $showCreateTagSheet) {
            createTagAtCommitSheet
        }
    }

    /// 单条 commit 行
    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主要内容
            HStack(spacing: 10) {
                // 短 hash
                Text(commit.shortOid)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.baizeAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.baizeAccent.opacity(0.1))
                    .cornerRadius(4)

                // 消息首行
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(commit.messageHeadline)
                            .font(.system(size: 14))
                            .foregroundColor(Color.baizeTextPrimary)
                            .lineLimit(expandedCommit == commit.id ? nil : 1)

                        // T02: Tag 徽章 — 如果该 commit 有 tag，显示 tag 名
                        if let tag = tagForCommit(commit) {
                            HStack(spacing: 2) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 9))
                                Text(tag.name)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(Color.baizeAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.baizeAccent.opacity(0.15))
                            .cornerRadius(4)
                        }
                    }

                    if expandedCommit == commit.id {
                        // 展开时显示完整消息
                        if commit.message != commit.messageHeadline {
                            Text(commit.message)
                                .font(.system(size: 13))
                                .foregroundColor(Color.baizeTextSecondary)
                                .padding(.top, 4)
                        }

                        // 详情信息
                        HStack(spacing: 8) {
                            Label(commit.author, systemImage: "person.fill")
                            Label(commit.email, systemImage: "envelope.fill")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeTextSecondary)
                        .padding(.top, 4)

                        Text(commit.date.formatted(date: .complete, time: .standard))
                            .font(.system(size: 11))
                            .foregroundColor(Color.baizeTextSecondary)
                            .padding(.top, 2)

                        Text("SHA: \(commit.oid)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.baizeTextSecondary)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                // 时间
                if expandedCommit != commit.id {
                    Text(commit.date, style: .relative)
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeTextSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.baizeCardBackground.opacity(0.3))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedCommit == commit.id {
                        expandedCommit = nil
                    } else {
                        expandedCommit = commit.id
                    }
                }
            }
            // T02: 长按菜单 — 重置到此提交 / 在此创建标签
            .contextMenu {
                Button {
                    commitToReset = commit
                    selectedResetMode = .mixed
                    showResetSheet = true
                } label: {
                    Label("重置到此提交", systemImage: "arrow.uturn.backward")
                }

                Button {
                    commitForTag = commit
                    tagAtCommitName = ""
                    tagAtCommitMessage = ""
                    showCreateTagSheet = true
                } label: {
                    Label("在此创建标签", systemImage: "tag")
                }
            }
        }
    }

    /// 查找指定 commit 的 tag（T02）
    private func tagForCommit(_ commit: GitCommit) -> GitTag? {
        return viewModel.tags.first { $0.oid == commit.oid }
    }

    /// 重置确认 Sheet（T02 #5）
    private var resetSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("重置到此提交")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    if let commit = commitToReset {
                        Text(commit.messageHeadline)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)

                        Text(commit.shortOid)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color.baizeTextSecondary)
                    }
                }

                // Reset 模式选择
                VStack(spacing: 8) {
                    ForEach(GitResetMode.allCases, id: \.self) { mode in
                        Button(action: {
                            selectedResetMode = mode
                        }) {
                            HStack {
                                Image(systemName: selectedResetMode == mode ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedResetMode == mode ? Color.baizeAccent : Color.baizeTextSecondary)
                                Text(mode.displayName)
                                    .font(.system(size: 14))
                                    .foregroundColor(Color.baizeTextPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                selectedResetMode == mode
                                    ? Color.baizeAccent.opacity(0.1)
                                    : Color.baizeCardBackground
                            )
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)

                if selectedResetMode == .hard {
                    Text("⚠️ Hard 模式将丢弃所有未提交改动，此操作不可撤销！")
                        .font(.system(size: 12))
                        .foregroundColor(Color.baizeError)
                        .padding(.horizontal, 24)
                }

                Spacer()

                // 操作按钮
                HStack(spacing: 12) {
                    Button("取消") {
                        showResetSheet = false
                        commitToReset = nil
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("重置") {
                        if let commit = commitToReset {
                            Task {
                                await viewModel.reset(to: commit.oid, mode: selectedResetMode)
                                showResetSheet = false
                                commitToReset = nil
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        selectedResetMode == .hard
                            ? Color.baizeError
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
    }

    /// 在指定 commit 创建标签 Sheet（T02 #6）
    private var createTagAtCommitSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("创建标签")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    if let commit = commitForTag {
                        Text("在 \(commit.shortOid) 上创建")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                TextField("标签名（如: v1.0.0）", text: $tagAtCommitName)
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

                TextField("标签消息（留空则创建轻量标签）", text: $tagAtCommitMessage, axis: .vertical)
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
                    .lineLimit(3...6)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Spacer()

                // 操作按钮
                HStack(spacing: 12) {
                    Button("取消") {
                        showCreateTagSheet = false
                        commitForTag = nil
                        tagAtCommitName = ""
                        tagAtCommitMessage = ""
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("创建") {
                        if let commit = commitForTag {
                            Task {
                                await viewModel.createTag(
                                    name: tagAtCommitName,
                                    message: tagAtCommitMessage.isEmpty ? nil : tagAtCommitMessage,
                                    targetOid: commit.oid
                                )
                                showCreateTagSheet = false
                                commitForTag = nil
                                tagAtCommitName = ""
                                tagAtCommitMessage = ""
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        tagAtCommitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.baizeAccent.opacity(0.5)
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                    .disabled(tagAtCommitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
    }
}
