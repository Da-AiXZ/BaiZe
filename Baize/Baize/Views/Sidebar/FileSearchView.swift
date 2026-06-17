import SwiftUI

/// 文件搜索视图 — 支持文件名搜索 + 文件内容 Grep 搜索
/// 独立搜索面板，可通过文件浏览器搜索栏进入
struct FileSearchView: View {
    @ObservedObject var appState: AppState
    @State private var searchText = ""
    @State private var searchMode: SearchMode = .fileName
    @State private var results: [SearchResultItem] = []
    @State private var isSearching = false

    private let fileSystemService = FileSystemService()

    enum SearchMode: String, CaseIterable {
        case fileName = "文件名"
        case content = "文件内容"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索模式切换
            Picker("搜索模式", selection: $searchMode) {
                ForEach(SearchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 搜索输入
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("输入搜索关键词...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { performSearch() }

                if isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if !searchText.isEmpty {
                    Button(action: { searchText = ""; results = [] }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.baizeCardBackground)
            .cornerRadius(8)
            .padding(.horizontal, 12)

            // 搜索结果列表
            List(results) { result in
                SearchResultRow(result: result, appState: appState)
            }
            .listStyle(.plain)
        }
        .navigationTitle("搜索")
    }

    private func performSearch() {
        guard !searchText.isEmpty else { results = []; return }
        isSearching = true

        Task {
            switch searchMode {
            case .fileName:
                let filePaths = (try? fileSystemService.searchFiles(pattern: searchText)) ?? []
                results = filePaths.map { path in
                    SearchResultItem(
                        name: path.fileName,
                        path: path,
                        lineNumber: nil,
                        contentPreview: nil
                    )
                }

            case .content:
                let searchResults = (try? fileSystemService.searchContent(pattern: searchText)) ?? []
                results = searchResults.map { sr in
                    SearchResultItem(
                        name: sr.filePath.fileName,
                        path: sr.filePath,
                        lineNumber: sr.lineNumber,
                        contentPreview: sr.content
                    )
                }
            }
            isSearching = false
        }
    }
}

// MARK: - Search Result Item

/// 搜索结果项数据模型
struct SearchResultItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let lineNumber: Int?
    let contentPreview: String?
}

// MARK: - Search Result Row

/// 搜索结果行视图
struct SearchResultRow: View {
    let result: SearchResultItem
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 文件名 + 行号
            HStack(spacing: 4) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))

                if let line = result.lineNumber {
                    Text("行 \(line)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(2)
                }
            }

            // 文件路径
            Text(result.path)
                .font(.caption)
                .foregroundColor(.secondary)

            // 内容预览（Grep 搜索结果）
            if let preview = result.contentPreview {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.openFile(at: result.path)
        }
    }
}