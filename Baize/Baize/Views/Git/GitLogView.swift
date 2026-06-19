import SwiftUI

/// Git 提交历史视图 — commit 列表，短 hash/作者/相对时间/message
struct GitLogView: View {
    @ObservedObject var viewModel: GitViewModel
    @State private var expandedCommit: GitCommit.ID?

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
                    Text(commit.messageHeadline)
                        .font(.system(size: 14))
                        .foregroundColor(Color.baizeTextPrimary)
                        .lineLimit(expandedCommit == commit.id ? nil : 1)

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
        }
    }
}
