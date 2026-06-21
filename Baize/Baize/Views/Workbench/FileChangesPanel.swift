import SwiftUI

/// 文件改动面板 — 展示 Git 工作区的文件变更
@MainActor
struct FileChangesPanel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let gitVM = appState.gitViewModel {
            if let status = gitVM.status {
                if !status.hasChanges {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.baizeSuccess)
                        Text("工作区干净")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        // 合并所有变更文件
                        let allFiles = status.modified + status.staged + status.untracked
                        ForEach(allFiles) { file in
                            fileRow(file)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    if gitVM.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(gitVM.isNotAGitRepository ? "非 Git 仓库" : "加载中...")
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

    /// 文件行
    private func fileRow(_ file: GitFileStatus) -> some View {
        HStack(spacing: 10) {
            // 变更状态图标
            Text(file.changeStatus.icon)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(file.changeStatus.color)
                .frame(width: 20, alignment: .center)

            // 文件名
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !file.path.isEmpty {
                    Text((file.path as NSString).deletingLastPathComponent)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.baizeCardBackground.opacity(0.5))
        .cornerRadius(6)
    }
}
