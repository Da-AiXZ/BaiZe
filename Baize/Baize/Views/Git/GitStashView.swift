import SwiftUI

/// Git 贮藏子 Tab 视图（T02 #4）— 显示 stash 列表，每行支持 Pop / Drop，底部有 Stash Push 按钮
struct GitStashView: View {
    @ObservedObject var viewModel: GitViewModel

    @State private var showStashPush: Bool = false
    @State private var stashMessage: String = ""
    @State private var stashToPop: GitStashEntry?
    @State private var stashToDrop: GitStashEntry?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.stashList.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无贮藏")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("工作区改动可以贮藏起来，稍后恢复")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.stashList) { entry in
                        stashRow(entry)
                    }
                }

                // Stash Push 按钮
                Button(action: {
                    showStashPush = true
                    stashMessage = ""
                }) {
                    HStack {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 18))
                        Text("贮藏当前改动")
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
                .disabled(viewModel.isStashing)
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            if viewModel.stashList.isEmpty {
                Task { await viewModel.loadStashList() }
            }
        }
        .sheet(isPresented: $showStashPush) {
            stashPushSheet
        }
        .confirmationDialog(
            "恢复贮藏 stash@{\(stashToPop?.index ?? 0)}？",
            isPresented: Binding(
                get: { stashToPop != nil },
                set: { if !$0 { stashToPop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("恢复并删除 (Pop)") {
                if let entry = stashToPop {
                    Task {
                        await viewModel.stashPop(index: entry.index)
                        stashToPop = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                stashToPop = nil
            }
        } message: {
            Text("将恢复贮藏的改动到工作区，并从贮藏列表中移除。如果有冲突，贮藏将保留。")
        }
        .confirmationDialog(
            "删除贮藏 stash@{\(stashToDrop?.index ?? 0)}？",
            isPresented: Binding(
                get: { stashToDrop != nil },
                set: { if !$0 { stashToDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除 (Drop)", role: .destructive) {
                if let entry = stashToDrop {
                    Task {
                        await viewModel.stashDrop(index: entry.index)
                        stashToDrop = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                stashToDrop = nil
            }
        } message: {
            Text("此操作不可撤销，贮藏的改动将永久丢失。")
        }
    }

    /// 单条 stash 行
    private func stashRow(_ entry: GitStashEntry) -> some View {
        HStack(spacing: 10) {
            // 贮藏图标
            Image(systemName: "tray.fill")
                .font(.system(size: 16))
                .foregroundColor(Color.baizeAccent)

            VStack(alignment: .leading, spacing: 3) {
                // stash@{index}
                Text("stash@{\(entry.index)}")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.baizeAccent)

                // 消息
                Text(entry.message)
                    .font(.system(size: 14))
                    .foregroundColor(Color.baizeTextPrimary)
                    .lineLimit(2)

                // 相对时间
                Text(entry.date, style: .relative)
                    .font(.system(size: 11))
                    .foregroundColor(Color.baizeTextSecondary)
            }

            Spacer()

            // Pop 按钮
            Button(action: {
                stashToPop = entry
            }) {
                Text("Pop")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.baizeAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.baizeAccent.opacity(0.1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStashing)

            // Drop 按钮
            Button(action: {
                stashToDrop = entry
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(Color.baizeError)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStashing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.baizeCardBackground.opacity(0.3))
    }

    /// Stash Push 弹窗
    private var stashPushSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 8) {
                    Text("贮藏当前改动")
                        .font(.title2.bold())
                        .foregroundColor(Color.baizeTextPrimary)

                    Text("将工作区和暂存区的改动保存到贮藏栈")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                TextField("贮藏消息（可选）", text: $stashMessage)
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
                        showStashPush = false
                        stashMessage = ""
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(10)

                    Button("贮藏") {
                        Task {
                            await viewModel.stashPush(message: stashMessage)
                            showStashPush = false
                            stashMessage = ""
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        viewModel.isStashing
                            ? Color.baizeAccent.opacity(0.5)
                            : Color.baizeAccent
                    )
                    .cornerRadius(10)
                    .disabled(viewModel.isStashing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium])
    }
}
