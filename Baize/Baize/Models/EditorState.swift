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
    func closeTab(_ tab: EditorTab) {
        openTabs.removeAll { $0.id == tab.id }
        if activeTab == tab {
            activeTab = openTabs.last
        }
    }

    /// 切换到指定 Tab
    func switchToTab(_ tab: EditorTab) {
        activeTab = tab
    }

    /// 更新当前文件内容（来自 Monaco Bridge 的变更回调）
    func updateContent(_ content: String) {
        currentContent = content
        hasUnsavedChanges = true
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