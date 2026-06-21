import SwiftUI

// MARK: - Session List View (P1-1 + T05: #15 会话搜索 + #16 导出对话)

/// 会话列表视图 — 显示已保存的对话，支持选择恢复或新建
/// T05 新增：会话全文搜索（debounce 300ms）+ 导出对话（MD/TXT/JSON + 精简/完整 + ShareSheet）
struct SessionListView: View {
    let sessions: [ConversationSession]
    let currentSessionId: UUID?
    let onSelect: (ConversationSession) -> Void
    let onNewSession: () -> Void
    /// T05: 当前项目路径（用于搜索过滤 + 导出路径）
    let projectPath: String
    /// T05: ConversationStore 实例（用于搜索，actor 异步调用）
    let conversationStore: ConversationStore?

    // T05: 搜索状态
    @State private var searchText: String = ""
    @State private var searchResults: [SessionSearchResult] = []
    @State private var isSearching: Bool = false
    /// debounce：300ms 延迟搜索，避免每次按键都触发
    @State private var searchDebounceTask: Task<Void, Never>?

    // T05: 导出状态
    @State private var exportSession: ConversationSession?
    @State private var showFormatSelection: Bool = false
    @State private var selectedFormat: ExportFormat = .markdown
    @State private var showContentModeSelection: Bool = false
    @State private var exportError: String?
    @State private var showExportError: Bool = false
    @State private var exportedFileURL: URL?
    @State private var showShareSheet: Bool = false

    /// 是否正在搜索（搜索框有内容）
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // T05: 搜索框
                searchBar

                // 会话列表 / 搜索结果
                List {
                    // 顶部新建会话按钮
                    Section {
                        Button(action: onNewSession) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.baizeAccent)
                                Text("新建会话")
                                    .foregroundColor(.baizeAccent)
                            }
                        }
                    }

                    if isSearchActive {
                        // 搜索结果
                        searchResultsSection
                    } else {
                        // 完整会话列表
                        sessionListSection
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
            // T05: 导出格式选择 sheet
            .sheet(isPresented: $showFormatSelection) {
                if let session = exportSession {
                    ExportFormatSelectionSheet(
                        session: session,
                        onSelectFormat: { format in
                            selectedFormat = format
                            showFormatSelection = false
                            showContentModeSelection = true
                        }
                    )
                }
            }
            // T05: 内容模式选择 sheet
            .sheet(isPresented: $showContentModeSelection) {
                if let session = exportSession {
                    ExportContentModeSheet(
                        session: session,
                        format: selectedFormat,
                        onSelectMode: { mode in
                            showContentModeSelection = false
                            performExport(session: session, format: selectedFormat, contentMode: mode)
                        }
                    )
                }
            }
            // T05: ShareSheet — 分享导出的文件
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(items: [url])
                }
            }
            // T05: 导出错误提示
            .alert("导出失败", isPresented: $showExportError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(exportError ?? "未知错误")
            }
        }
    }

    // MARK: - Search Bar

    /// 搜索框 — 放大镜图标 + TextField + 清除按钮
    /// debounce 300ms：用户输入后延迟 300ms 才触发搜索，避免频繁查询
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField("搜索对话内容...", text: $searchText)
                .font(.system(size: 14))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: searchText) { newValue in
                    handleSearchDebounce(newValue)
                }

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    searchResults = []
                    searchDebounceTask?.cancel()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Search Debounce

    /// debounce 300ms 搜索 — 用户输入后延迟 300ms 才执行搜索
    /// 避免每次按键都触发 ConversationStore.search()
    /// - Parameter query: 搜索关键词
    private func handleSearchDebounce(_ query: String) {
        searchDebounceTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchDebounceTask = Task {
            // debounce 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            await performSearch(query: trimmed)
        }
    }

    /// 执行搜索 — 调用 ConversationStore.search()（在 actor 内执行，避免阻塞 UI）
    /// - Parameter query: 搜索关键词
    @MainActor
    private func performSearch(query: String) async {
        guard let store = conversationStore else {
            isSearching = false
            return
        }

        let results = await store.search(query: query, projectPath: projectPath)

        // 防止竞态：检查搜索词是否仍然匹配（用户可能已修改输入）
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query {
            searchResults = results
            isSearching = false
        }
    }

    // MARK: - Session List Section

    /// 完整会话列表（无搜索时显示）
    private var sessionListSection: some View {
        Section {
            if sessions.isEmpty {
                Text("暂无历史会话")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isCurrent: session.id == currentSessionId
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(session)
                    }
                    // T05: swipeActions 导出按钮
                    .swipeActions(edge: .trailing) {
                        Button {
                            exportSession = session
                            showFormatSelection = true
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                        .tint(.baizeAccent)
                    }
                }
            }
        }
    }

    // MARK: - Search Results Section

    /// 搜索结果列表 — 显示标题 + 匹配片段（关键词高亮）+ 匹配消息数
    private var searchResultsSection: some View {
        Section {
            if searchResults.isEmpty && !isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("未找到匹配的对话")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                    ForEach(searchResults) { result in
                        SessionSearchResultRow(
                            result: result,
                            searchQuery: searchText
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 点击搜索结果 → 加载该会话
                            if let session = sessions.first(where: { $0.id == result.sessionId }) {
                                onSelect(session)
                            }
                        }
                }
            }
        }
    }

    // MARK: - Export

    /// 执行导出 — 调用 ConversationExporter.export()，成功后弹出 ShareSheet
    /// - Parameters:
    ///   - session: 要导出的会话
    ///   - format: 导出格式（markdown / plaintext / json）
    ///   - contentMode: 内容模式（minimal / full）
    private func performExport(session: ConversationSession, format: ExportFormat, contentMode: ExportContentMode) {
        Task {
            let exporter = ConversationExporter()
            do {
                let url = try exporter.export(
                    session: session,
                    format: format,
                    projectPath: projectPath,
                    contentMode: contentMode
                )
                await MainActor.run {
                    self.exportedFileURL = url
                    self.showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.exportError = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
    }
}

// MARK: - Session Row

/// 单个会话行 — 标题 + 相对时间 + 消息数
struct SessionRow: View {
    let session: ConversationSession
    let isCurrent: Bool

    /// 会话标题：优先用首条用户消息前 30 字，否则用 session.title
    private var displayTitle: String {
        for message in session.messages {
            if case .user(let text) = message {
                let firstLine = text.split(separator: "\n").first ?? ""
                let title = String(firstLine.prefix(30))
                return title.isEmpty ? session.title : title
            }
        }
        return session.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.baizeSuccess)
                }
                Text(displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.baizeTextPrimary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(session.updatedAt.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)

                Text("\(session.messages.count) 条消息")
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Search Result Row (T05: #15)

/// 搜索结果行 — 会话标题 + 匹配片段（关键词高亮）+ 匹配消息数
struct SessionSearchResultRow: View {
    let result: SessionSearchResult
    /// 当前搜索关键词（用于高亮匹配文本）
    let searchQuery: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 会话标题
            Text(result.sessionTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.baizeTextPrimary)
                .lineLimit(1)

            // 匹配片段（关键词高亮）
            Text(highlightedText(result.matchedSnippet, keyword: searchQuery))
                .font(.system(size: 12))
                .foregroundColor(.baizeTextSecondary)
                .lineLimit(3)

            // 匹配消息数
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                Text("\(result.matchCount) 条匹配")
                    .font(.caption2)
            }
            .foregroundColor(.baizeAccent)
        }
        .padding(.vertical, 2)
    }

    /// 生成带高亮的 AttributedString — 关键词部分用黄色背景标记
    /// - Parameters:
    ///   - text: 原始文本
    ///   - keyword: 搜索关键词（大小写不敏感高亮）
    /// - Returns: 关键词高亮的 AttributedString
    private func highlightedText(_ text: String, keyword: String) -> AttributedString {
        var attributed = AttributedString(text)

        // 大小写不敏感查找关键词位置
        let lowerText = text.lowercased()
        let lowerKeyword = keyword.lowercased()
        var searchStart = lowerText.startIndex

        while searchStart < lowerText.endIndex,
              let range = lowerText.range(of: lowerKeyword, range: searchStart..<lowerText.endIndex) {
            // 将 String.Index 转换为 AttributedString 的范围
            let lowerStart = lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)
            let length = lowerText.distance(from: range.lowerBound, to: range.upperBound)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: lowerStart)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: length)

            if attrStart < attributed.endIndex && attrEnd <= attributed.endIndex {
                attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                attributed[attrStart..<attrEnd].foregroundColor = .primary
            }

            searchStart = range.upperBound
        }

        return attributed
    }
}

// MARK: - Export Format Selection Sheet (T05: #16)

/// 导出格式选择 sheet — Markdown / 纯文本 / JSON
struct ExportFormatSelectionSheet: View {
    let session: ConversationSession
    let onSelectFormat: (ExportFormat) -> Void

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("选择导出格式")) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(action: { onSelectFormat(format) }) {
                            HStack {
                                Image(systemName: formatIcon(format))
                                    .foregroundColor(.baizeAccent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.displayName)
                                        .foregroundColor(.primary)
                                    Text(formatDescription(format))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("导出对话")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 格式对应的图标
    private func formatIcon(_ format: ExportFormat) -> String {
        switch format {
        case .markdown: return "doc.richtext"
        case .plaintext: return "doc.text"
        case .json: return "curlybraces"
        }
    }

    /// 格式描述
    private func formatDescription(_ format: ExportFormat) -> String {
        switch format {
        case .markdown: return "包含标题、角色标签、代码块格式"
        case .plaintext: return "纯文本，适合复制粘贴"
        case .json: return "完整结构化数据，含元信息"
        }
    }
}

// MARK: - Export Content Mode Selection Sheet (T05: #16)

/// 内容模式选择 sheet — 精简 / 完整
struct ExportContentModeSheet: View {
    let session: ConversationSession
    let format: ExportFormat
    let onSelectMode: (ExportContentMode) -> Void

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("选择内容模式")) {
                    Button(action: { onSelectMode(.minimal) }) {
                        HStack {
                            Image(systemName: "doc")
                                .foregroundColor(.baizeAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("精简模式")
                                    .foregroundColor(.primary)
                                Text("仅对话文本，不含工具调用结果")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { onSelectMode(.full) }) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.baizeAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("完整模式")
                                    .foregroundColor(.primary)
                                Text("包含工具调用参数和执行结果")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section(header: Text("预览")) {
                    Text("会话: \(session.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("消息数: \(session.messages.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("格式: \(format.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("内容模式")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
