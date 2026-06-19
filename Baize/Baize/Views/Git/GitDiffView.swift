import SwiftUI

/// Git Diff 查看器 — P0 纯文本 SwiftUI List，+ 行绿色 / - 行红色
struct GitDiffView: View {
    @ObservedObject var viewModel: GitViewModel
    let filePath: String
    let diffType: GitDiffType

    @State private var diffResult: GitDiffResult?
    @State private var isLoading: Bool = false

    var body: some View {
        ScrollView {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("加载 diff...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else if let result = diffResult {
                if result.hunks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("无差异内容")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.hunks) { hunk in
                            hunkView(hunk)
                        }
                    }
                    .padding(.bottom, 20)
                }
            } else {
                Text("无法加载 diff")
                    .foregroundColor(.secondary)
                    .padding(.top, 60)
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Text(diffType.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.baizeCardBackground)
                    .cornerRadius(6)
            }
        }
        .onAppear {
            loadDiff()
        }
    }

    /// 单个 hunk 的渲染
    private func hunkView(_ hunk: GitDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header: @@ -oldStart,oldLines +newStart,newLines @@
            HStack(spacing: 4) {
                Text("@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.baizeAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.baizeCardBackground.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)

            // Diff 行
            ForEach(hunk.lines) { line in
                diffLineView(line)
            }
        }
    }

    /// 单行 diff 渲染
    private func diffLineView(_ line: GitDiffLine) -> some View {
        HStack(spacing: 0) {
            // 前缀符号
            Text(line.type.prefix)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(line.type.color)
                .frame(width: 20, alignment: .center)

            // 行内容
            Text(line.content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(line.type.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(lineBackgroundColor(for: line.type))
    }

    /// 行背景色 — 根据行类型微调
    private func lineBackgroundColor(for type: GitDiffLineType) -> Color {
        switch type {
        case .addition:
            return Color.baizeSuccess.opacity(0.08)
        case .deletion:
            return Color.baizeError.opacity(0.08)
        case .context:
            return Color.clear
        }
    }

    /// 加载 diff 数据
    private func loadDiff() {
        isLoading = true
        Task {
            await viewModel.loadDiff(filePath: filePath, diffType: diffType)
            await MainActor.run {
                self.diffResult = viewModel.selectedDiff
                self.isLoading = false
            }
        }
    }
}
