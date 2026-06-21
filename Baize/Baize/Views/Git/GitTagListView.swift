import SwiftUI

/// Git 标签列表视图（T02 #6）— 显示所有 tag，支持在指定 commit 创建标签和删除标签
struct GitTagListView: View {
    @ObservedObject var viewModel: GitViewModel

    @State private var showCreateTag: Bool = false
    @State private var newTagName: String = ""
    @State private var newTagMessage: String = ""
    @State private var targetOid: String?
    @State private var tagToDelete: GitTag?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.tags.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无标签")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("在指定提交上创建标签以标记重要版本")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.tags) { tag in
                        tagRow(tag)
                    }
                }

                // 创建标签按钮
                Button(action: {
                    showCreateTag = true
                    newTagName = ""
                    newTagMessage = ""
                    targetOid = nil
                }) {
                    HStack {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 18))
                        Text("新建标签")
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
            if viewModel.tags.isEmpty {
                Task { await viewModel.loadTags() }
            }
        }
        .sheet(isPresented: $showCreateTag) {
            createTagSheet
        }
        .confirmationDialog(
            "删除标签 \(tagToDelete?.name ?? "")？",
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { if !$0 { tagToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let tag = tagToDelete {
                    Task {
                        await viewModel.deleteTag(name: tag.name)
                        tagToDelete = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                tagToDelete = nil
            }
        } message: {
            Text("此操作不可撤销。")
        }
    }

    /// 单条 tag 行
    private func tagRow(_ tag: GitTag) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // 标签图标
                Image(systemName: tag.isAnnotated ? "tag.fill" : "tag")
                    .font(.system(size: 16))
                    .foregroundColor(Color.baizeAccent)

                VStack(alignment: .leading, spacing: 2) {
                    // 标签名
                    Text(tag.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color.baizeTextPrimary)

                    // OID
                    Text(String(tag.oid.prefix(7)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.baizeTextSecondary)

                    // 时间
                    Text(tag.date, style: .relative)
                        .font(.system(size: 11))
                        .foregroundColor(Color.baizeTextSecondary)
                }

                Spacer()

                // 附注标签标记
                if tag.isAnnotated {
                    Text("附注")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.baizeAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.baizeAccent.opacity(0.1))
                        .cornerRadius(4)
                }

                // 删除按钮
                Button(action: {
                    tagToDelete = tag
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(Color.baizeError)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            // 标签消息（附注标签）
            if let message = tag.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(Color.baizeTextSecondary)
                    .padding(.leading, 26)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.baizeCardBackground.opacity(0.3))
    }

    /// 创建标签 Sheet
    private var createTagSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("新建标签")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    if let oid = targetOid {
                        Text("在 commit \(String(oid.prefix(7))) 上创建")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("在当前 HEAD 上创建")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                TextField("标签名（如: v1.0.0）", text: $newTagName)
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

                TextField("标签消息（留空则创建轻量标签）", text: $newTagMessage, axis: .vertical)
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
                        showCreateTag = false
                        newTagName = ""
                        newTagMessage = ""
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("创建") {
                        Task {
                            await viewModel.createTag(
                                name: newTagName,
                                message: newTagMessage.isEmpty ? nil : newTagMessage,
                                targetOid: targetOid
                            )
                            showCreateTag = false
                            newTagName = ""
                            newTagMessage = ""
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.baizeAccent.opacity(0.5)
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
    }
}
