import SwiftUI

/// Diff 视图 — 展示代码差异（增强版，支持 AI 编辑 diff 可视化）
@MainActor
struct DiffViewer: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let gitVM = appState.gitViewModel {
            if let status = gitVM.status, status.hasChanges {
                VStack(alignment: .leading, spacing: 8) {
                    Text("点击文件查看差异")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // 文件列表 — 点击跳转到 GitDiffView
                    let allFiles = status.modified + status.staged + status.untracked
                    ForEach(allFiles.prefix(10)) { file in
                        NavigationLink(
                            destination: GitDiffView(
                                viewModel: gitVM,
                                filePath: file.path,
                                diffType: file.isStaged ? .indexVsHead : .workingTreeVsIndex
                            )
                        ) {
                            HStack(spacing: 8) {
                                Text(file.changeStatus.icon)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(file.changeStatus.color)
                                Text(file.displayName)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.baizeCardBackground.opacity(0.5))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    if allFiles.count > 10 {
                        Text("... 还有 \(allFiles.count - 10) 个文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("无代码差异")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        } else {
            Text("Git 服务未初始化")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
    }
}
