import SwiftUI

/// 文件浏览器完整视图 — 树形目录结构 + 文件搜索 + 右键菜单 + BAIZE.md 高亮
/// 使用 FileSystemService 加载真实文件系统
/// OutlineGroup 递归展示目录结构，延迟加载子节点
struct FileExplorerView: View {
    @ObservedObject var appState: AppState
    @State private var rootItems: [FileItem] = []
    @State private var selectedFilePath: String?
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var expandedPaths: Set<String> = []

    private let fileSystemService = FileSystemService()

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
                    OutlineGroup(rootItems, children: \.children) { item in
                        FileItemRow(
                            item: item,
                            isSelected: selectedFilePath == item.path,
                            onTap: { handleItemTap(item) }
                        )
                        .contextMenu { FileItemContextMenu(item: item, appState: appState) }
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
            rootItems = try fileSystemService.listDirectory(at: appState.currentProjectPath)
            // 为目录项延迟加载子节点
            for index in rootItems.indices {
                if rootItems[index].isDirectory {
                    rootItems[index].children = try? fileSystemService.listDirectory(at: rootItems[index].path)
                }
            }
            isLoading = false
        } catch {
            appState.showError("无法加载目录: \(error.localizedDescription)")
            isLoading = false
        }
    }

    /// 递归加载目录的子节点
    private func loadChildren(for item: FileItem) -> [FileItem]? {
        guard item.isDirectory else { return nil }
        return try? fileSystemService.listDirectory(at: item.path)
    }

    private func handleItemTap(_ item: FileItem) {
        if item.isDirectory {
            // 切换展开/折叠状态
            if expandedPaths.contains(item.path) {
                expandedPaths.remove(item.path)
            } else {
                expandedPaths.insert(item.path)
            }
        } else {
            selectedFilePath = item.path
            appState.openFile(at: item.path)

            // 读取文件内容并在 Monaco Editor 中打开
            do {
                let content = try fileSystemService.readFile(at: item.path)
                // 通知 EditorState 打开文件（通过 AppState 传递）
                appState.selectedFilePath = item.path
            } catch {
                appState.showError("无法打开文件: \(error.localizedDescription)")
            }
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

// MARK: - File Item Row

/// 文件/目录行视图 — 显示图标 + 文件名 + BAIZE.md 配置标记
struct FileItemRow: View {
    let item: FileItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
struct FileItemContextMenu: View {
    let item: FileItem
    @ObservedObject var appState: AppState
    @State private var isShowingNewFileSheet = false
    @State private var isShowingDeleteConfirmation = false

    private let fileSystemService = FileSystemService()

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
struct NewFileSheet: View {
    let parentPath: String
    @State private var fileName = ""
    @State private var isFolder = false
    @Environment(\.dismiss) private var dismiss

    private let fileSystemService = FileSystemService()

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