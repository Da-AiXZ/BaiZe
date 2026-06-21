import SwiftUI

/// 文件浏览器完整视图 — 树形目录结构 + 文件搜索 + 右键菜单 + BAIZE.md 高亮
/// W5 fix: 使用 AppState 共享的 FileSystemService，避免创建独立实例
struct FileExplorerView: View {
    @ObservedObject var appState: AppState
    @State private var rootItems: [FileItem] = []
    @State private var selectedFilePath: String?
    @State private var isLoading = false
    @State private var searchText = ""

    /// W5 fix: 从 AppState 获取共享 FileSystemService（延迟初始化）
    /// W15/W21 fix: fallback 使用 appState.currentProjectPath 而非默认路径
    /// T03: 文件树根目录已从 BaizePath.projectRoot 改为 appState.currentProjectPath，
    /// 切换项目时通过 onChange(of: appState.currentProjectPath) 自动刷新
    private var fileSystemService: FileSystemService {
        guard let shared = appState.fileSystemService else {
            let fallback = FileSystemService(rootPath: appState.currentProjectPath)
            fallback.setRootPath(appState.currentProjectPath)
            return fallback
        }
        return shared
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            FileSearchBar(text: $searchText, onSearch: { searchFiles() })

            // 文件树列表
            if isLoading {
                ProgressView("加载文件...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Bug 1 fix: 用递归 DisclosureGroup 替代 OutlineGroup，
                    // 解决深层目录 children=nil 无法展开的问题。
                    // 每个目录节点独立懒加载子项，展开时才读取磁盘。
                    ForEach(rootItems) { item in
                        FileTreeNode(
                            item: item,
                            selectedFilePath: $selectedFilePath,
                            appState: appState,
                            fileSystemService: fileSystemService
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("项目文件")
        .task { loadRootDirectory() }
        .onChange(of: appState.currentProjectPath) { _ in loadRootDirectory() }
    }

    // MARK: - File Loading

    private func loadRootDirectory() {
        isLoading = true
        fileSystemService.setRootPath(appState.currentProjectPath)

        do {
            // Bug 1 fix: 只加载根目录项，子目录的 children 由 FileTreeNode 展开时懒加载
            rootItems = try fileSystemService.listDirectory(at: appState.currentProjectPath)
            isLoading = false
        } catch {
            appState.showError("无法加载目录: \(error.localizedDescription)")
            isLoading = false
        }
    }

    private func searchFiles() {
        guard !searchText.isEmpty else { loadRootDirectory(); return }

        do {
            let results = try fileSystemService.searchFiles(pattern: searchText)
            // 将搜索结果映射为 FileItem 列表（扁平化）
            rootItems = results.map { path in
                FileItem(
                    name: path.fileName,
                    path: path,
                    isDirectory: false,
                    children: nil,
                    size: FileManager.default.fileSize(atPath: path) ?? 0,
                    modifiedAt: FileManager.default.fileModifiedDate(atPath: path) ?? Date()
                )
            }
        } catch {
            appState.showError("搜索失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - File Tree Node (Recursive — Bug 1 fix)

/// 递归文件树节点 — 使用 DisclosureGroup 实现目录的展开/折叠
///
/// Bug 1 fix: 替代 OutlineGroup，解决深层目录 children=nil 无法展开的问题。
/// 每个目录节点独立管理自己的展开状态和子节点懒加载：
/// - 点击目录时 DisclosureGroup 自动切换展开/折叠
/// - 首次展开时从磁盘读取子项（懒加载），避免一次性加载整棵树
/// - 子目录同样使用 FileTreeNode 递归渲染，支持无限层级展开
struct FileTreeNode: View {
    let item: FileItem
    @Binding var selectedFilePath: String?
    let appState: AppState
    let fileSystemService: FileSystemService

    /// 子节点列表（展开时懒加载）
    @State private var children: [FileItem] = []
    /// 是否已加载过子节点（避免重复加载）
    @State private var hasLoadedChildren: Bool = false
    /// 是否正在加载子节点
    @State private var isLoadingChildren: Bool = false
    /// 当前展开状态（DisclosureGroup 绑定）
    @State private var isExpanded: Bool = false

    var body: some View {
        if item.isDirectory {
            directoryNode
        } else {
            fileNode
        }
    }

    // MARK: - Directory Node

    private var directoryNode: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isLoadingChildren {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 8)
            } else if hasLoadedChildren {
                if children.isEmpty {
                    Text("(空)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                } else {
                    ForEach(children) { child in
                        FileTreeNode(
                            item: child,
                            selectedFilePath: $selectedFilePath,
                            appState: appState,
                            fileSystemService: fileSystemService
                        )
                    }
                }
            }
        } label: {
            FileItemRow(
                item: item,
                isSelected: false,
                onTap: {}
            )
        }
        .contextMenu { FileItemContextMenu(item: item, appState: appState) }
        .onChange(of: isExpanded) { expanded in
            if expanded && !hasLoadedChildren {
                Task { @MainActor in loadChildren() }
            }
        }
    }

    // MARK: - File Node

    private var fileNode: some View {
        FileItemRow(
            item: item,
            isSelected: selectedFilePath == item.path,
            onTap: { Task { @MainActor in openFile() } }
        )
        .contextMenu { FileItemContextMenu(item: item, appState: appState) }
    }

    // MARK: - Actions

    /// 打开文件 — 通知 AppState 并读取内容
    private func openFile() {
        selectedFilePath = item.path
        appState.openFile(at: item.path)
        appState.selectedFilePath = item.path
    }

    /// 懒加载目录子项 — 首次展开时从磁盘读取
    private func loadChildren() {
        isLoadingChildren = true
        do {
            children = try fileSystemService.listDirectory(at: item.path)
            hasLoadedChildren = true
        } catch {
            appState.showError("无法加载目录: \(error.localizedDescription)")
        }
        isLoadingChildren = false
    }
}

// MARK: - File Item Row

/// 文件/目录行视图 — 显示图标 + 文件名 + BAIZE.md 配置标记
struct FileItemRow: View {
    let item: FileItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let rowContent = HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 16)

            Text(item.name)
                .font(.system(size: 13, weight: item.isBaizeConfig ? .semibold : .regular))
                .foregroundColor(item.isBaizeConfig ? Color.baizeAccent : .primary)
                .lineLimit(1)

            if item.isBaizeConfig {
                Text("配置")
                    .font(.caption2)
                    .foregroundColor(Color.baizeAccent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.baizeAccent.opacity(0.15))
                    .cornerRadius(3)
            }

            Spacer()

            // 文件大小（仅文件显示）
            if !item.isDirectory {
                Text(formatFileSize(item.size))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.baizeAccent.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())

        // Bug fix (P2): 目录的展开/折叠由 OutlineGroup 原生处理，
        // 不添加 onTapGesture，否则会拦截 OutlineGroup 的展开事件导致点击目录无反应。
        // 之前对所有项目（含目录）都添加了 onTapGesture，导致 .baize、.git 等目录点击无反应。
        // 文件仍保留 onTapGesture 以处理文件打开逻辑。
        if item.isDirectory {
            rowContent
        } else {
            rowContent.onTapGesture(perform: onTap)
        }
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        if item.isBaizeConfig { return "doc.text.fill" }
        switch item.fileExtension {
        case "swift": return "swift"
        case "py": return "doc.plaintext"
        case "tsx", "ts": return "doc.richtext"
        case "js": return "doc.richtext"
        case "json": return "doc.text"
        case "md": return "doc.text.fill"
        case "html": return "doc"
        case "css": return "doc"
        case "yaml", "yml": return "doc.text"
        case "sh": return "terminal"
        case "gitignore": return "doc"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if item.isDirectory { return Color.baizeFolder }
        if item.isBaizeConfig { return Color.baizeAccent }
        switch item.fileExtension {
        case "swift": return .orange
        case "py": return .blue
        case "tsx", "ts", "js": return .cyan
        default: return .secondary
        }
    }

    private func formatFileSize(_ size: Int64) -> String {
        if size < 1024 { return "\(size)B" }
        if size < 1024 * 1024 { return "\(size / 1024)KB" }
        return "\(size / (1024 * 1024))MB"
    }
}

// MARK: - File Item Context Menu

/// 文件/目录右键菜单 — 新建、重命名、删除
/// W5 fix: FileItemContextMenu 也使用 AppState 共享 FileSystemService
struct FileItemContextMenu: View {
    let item: FileItem
    @ObservedObject var appState: AppState
    @State private var isShowingNewFileSheet = false
    @State private var isShowingDeleteConfirmation = false

    /// W5 fix: 从 AppState 获取共享 FileSystemService
    /// W15/W21 fix: fallback 使用 appState.currentProjectPath 而非默认路径
    private var fileSystemService: FileSystemService {
        guard let shared = appState.fileSystemService else {
            let fallback = FileSystemService(rootPath: appState.currentProjectPath)
            fallback.setRootPath(appState.currentProjectPath)
            return fallback
        }
        return shared
    }

    var body: some View {
        Group {
            if item.isDirectory {
                Button(action: { isShowingNewFileSheet = true }) {
                    Label("新建文件", systemImage: "doc.badge.plus")
                }
                Button(action: { isShowingNewFileSheet = true }) {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
            }

            Button(action: { openInEditor() }) {
                Label("在编辑器中打开", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(item.isDirectory)

            Divider()

            Button(role: .destructive, action: { isShowingDeleteConfirmation = true }) {
                Label("删除", systemImage: "trash")
            }
        }
        .sheet(isPresented: $isShowingNewFileSheet) {
            NewFileSheet(parentPath: item.isDirectory ? item.path : item.path.directoryPath)
        }
        .alert("确认删除", isPresented: $isShowingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteItem() }
        } message: {
            Text("确定要删除 \(item.name) 吗？此操作不可撤销。")
        }
    }

    private func openInEditor() {
        appState.openFile(at: item.path)
    }

    private func deleteItem() {
        do {
            try fileSystemService.deleteItem(at: item.path)
            uiLogger.info("Deleted: \(item.name)")
        } catch {
            appState.showError(error.localizedDescription)
        }
    }
}

// MARK: - File Search Bar

/// 文件搜索栏
struct FileSearchBar: View {
    @Binding var text: String
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("搜索文件...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { onSearch() }

            if !text.isEmpty {
                Button(action: { text = ""; onSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.baizeCardBackground)
        .cornerRadius(6)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

// MARK: - New File Sheet

/// 新建文件/文件夹弹窗
/// W5 fix: NewFileSheet 也使用共享 FileSystemService（通过环境注入）
struct NewFileSheet: View {
    let parentPath: String
    @State private var fileName = ""
    @State private var isFolder = false
    @Environment(\.dismiss) private var dismiss
    /// W5 fix: 通过 @EnvironmentObject 获取 AppState 的共享 FileSystemService
    /// W15/W21 fix: fallback 使用 appState.currentProjectPath 而非默认路径
    @EnvironmentObject private var appState: AppState

    private var fileSystemService: FileSystemService {
        guard let shared = appState.fileSystemService else {
            let fallback = FileSystemService(rootPath: appState.currentProjectPath)
            fallback.setRootPath(appState.currentProjectPath)
            return fallback
        }
        return shared
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("文件名", text: $fileName)
                    .textFieldStyle(.roundedBorder)

                Toggle("创建文件夹", isOn: $isFolder)

                Spacer()
            }
            .padding()
            .navigationTitle("新建")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("创建") { createItem() } }
            }
        }
    }

    private func createItem() {
        let fullPath = (parentPath as NSString).appendingPathComponent(fileName)
        do {
            if isFolder {
                try fileSystemService.createDirectory(at: fullPath)
            } else {
                try fileSystemService.writeFile(at: fullPath, content: "")
            }
        } catch {
            // Error handling via AppState
        }
        dismiss()
    }
}