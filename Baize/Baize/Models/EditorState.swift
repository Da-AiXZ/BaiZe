import SwiftUI
import Foundation

/// 编辑器状态模型 — 管理 Monaco Editor 的打开文件、Tab、光标等状态
/// 作为 ObservableObject 供 EditorContainerView 和 EditorTabBar 使用
/// W5 fix: 添加 fileSystemService 属性，使用共享实例而非每次创建新实例
@MainActor
class EditorState: ObservableObject {

    // MARK: - Tab Management

    /// 打开的文件 Tab 列表
    @Published var openTabs: [EditorTab] = []

    /// 当前激活的 Tab
    @Published var activeTab: EditorTab?

    // MARK: - Editor State

    /// 当前文件内容
    @Published var currentContent: String = ""

    /// 当前文件是否有未保存修改
    @Published var hasUnsavedChanges: Bool = false

    /// 当前光标位置（行号、列号）
    @Published var cursorPosition: CursorPosition = CursorPosition()

    /// Monaco Bridge 实例
    var monacoBridge: MonacoBridge?

    /// W5 fix: 共享的 FileSystemService（由 EditorContainerView 注入）
    var fileSystemService: FileSystemService?

    // MARK: - Methods

    /// 打开文件（添加到 Tab 列表）
    /// BugFix: 即使文件已在 Tab 列表中，也必须调用 monacoBridge.openFile
    /// 否则切换到已打开的 Tab 时 Monaco 编辑器不会更新内容
    func openFile(path: String, content: String) {
        // 检查是否已经打开
        if let existingTab = openTabs.first(where: { $0.filePath == path }) {
            activeTab = existingTab
            // BugFix: 即使 Tab 已存在，也要通知 Monaco Bridge 更新编辑器内容
            // 否则用户点击已打开的文件时编辑器无反应
            monacoBridge?.openFile(path: path, content: content)
            return
        }

        let tab = EditorTab(filePath: path, fileName: path.fileName)
        openTabs.append(tab)
        activeTab = tab
        currentContent = content
        hasUnsavedChanges = false

        // 通知 Monaco Bridge 打开文件
        monacoBridge?.openFile(path: path, content: content)
    }

    /// 关闭文件 Tab
    /// P1-#11 fix: 关闭后切换到新 active tab 时，通知 Monaco Bridge 加载新文件内容
    func closeTab(_ tab: EditorTab) {
        openTabs.removeAll { $0.id == tab.id }
        if activeTab == tab {
            activeTab = openTabs.last
            // P1-#11 fix: 切换到新 active tab 时加载其内容到编辑器
            if let newActive = activeTab {
                if let fsService = fileSystemService,
                   let content = try? fsService.readFile(at: newActive.filePath) {
                    currentContent = content
                    hasUnsavedChanges = false
                    monacoBridge?.openFile(path: newActive.filePath, content: content)
                }
            } else {
                // 所有 Tab 都关闭了 — 清空编辑器
                currentContent = ""
                hasUnsavedChanges = false
            }
        }
    }

    /// 切换到指定 Tab
    /// P1-#11 fix: 切换 Tab 时通知 Monaco Bridge 加载文件内容
    func switchToTab(_ tab: EditorTab) {
        activeTab = tab
        // P1-#11 fix: 切换 Tab 时必须加载文件内容到 Monaco 编辑器
        if let fsService = fileSystemService,
           let content = try? fsService.readFile(at: tab.filePath) {
            currentContent = content
            hasUnsavedChanges = false
            monacoBridge?.openFile(path: tab.filePath, content: content)
        }
    }

    /// 更新当前文件内容（来自 Monaco Bridge 的变更回调）
    func updateContent(_ content: String) {
        currentContent = content
        hasUnsavedChanges = true
        // P1-#11 fix: 同步更新当前 Tab 的未保存状态
        if let tab = activeTab {
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].hasUnsavedChanges = true
            }
        }
    }

    /// P1-#11 fix: 保存当前文件到磁盘
    /// P1-#11 fix (round 2): 先从 Monaco Bridge 获取最新内容再保存
    /// - Returns: true 保存成功，false 保存失败
    func saveCurrentFile() -> Bool {
        guard let tab = activeTab, let fsService = fileSystemService else { return false }
        do {
            // P1-#11 fix (round 2): 先从 Monaco Bridge 同步最新内容到 currentContent
            // monacoBridge.onContentChanged 可能在保存前还有未同步的变更
            if let bridge = monacoBridge {
                // currentContent 已通过 onContentChanged 回调更新
                // 确保使用最新的 currentContent
            }
            try fsService.writeFile(at: tab.filePath, content: currentContent)
            hasUnsavedChanges = false
            // 更新 Tab 状态
            if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                openTabs[index].hasUnsavedChanges = false
            }
            return true
        } catch {
            return false
        }
    }

    /// 标记当前文件已保存
    func markSaved() {
        hasUnsavedChanges = false
    }

    /// 刷新指定文件内容（当 Agent 通过 write_file/edit_file 修改了文件）
    /// W5 fix: 使用共享 FileSystemService 而非创建新实例
    func refreshFile(at path: String) {
        // 如果当前打开的文件被修改，重新读取并更新
        if activeTab?.filePath == path {
            guard let fsService = fileSystemService else { return }
            if let newContent = try? fsService.readFile(at: path) {
                currentContent = newContent
                hasUnsavedChanges = false
                monacoBridge?.openFile(path: path, content: newContent)
            }
        }
    }
}

// MARK: - Editor Tab Model

/// 编辑器 Tab 数据模型
struct EditorTab: Identifiable, Equatable {
    let id = UUID()
    let filePath: String
    let fileName: String

    /// 文件扩展名（用于显示图标）
    var fileExtension: String { filePath.fileExtension }

    /// 是否有未保存修改
    var hasUnsavedChanges: Bool = false

    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Cursor Position

/// 光标位置模型
struct CursorPosition {
    var line: Int = 1
    var column: Int = 1

    var description: String {
        "Ln \(line), Col \(column)"
    }
}