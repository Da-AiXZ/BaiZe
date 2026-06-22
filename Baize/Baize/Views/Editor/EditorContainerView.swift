import SwiftUI
import WebKit

/// 编辑器容器视图 — 集成 MonacoBridge (WKWebView)
/// W5 fix: 使用 AppState 共享 FileSystemService，避免创建独立实例
/// 完整实现：Monaco Editor 加载 + 文件打开/编辑 + 内容变更检测 + 保存
/// 使用 @StateObject 管理 MonacoBridge 和 EditorState
struct EditorContainerView: View {
    @ObservedObject var appState: AppState
    @StateObject private var editorState = EditorState()
    @StateObject private var monacoBridge = MonacoBridge()

    var body: some View {
        VStack(spacing: 0) {
            // 多 Tab 栏
            EditorTabBar(editorState: editorState)

            // Monaco Editor WebView
            MonacoEditorWebView(monacoBridge: monacoBridge, editorState: editorState, appState: appState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.baizeEditorBackground)
        .onAppear {
            setupMonacoBridge()
        }
        .onChange(of: appState.selectedFilePath) { newPath in
            if let path = newPath {
                openFileInEditor(path: path)
            }
        }
    }

    // MARK: - Setup

    /// 初始化 MonacoBridge 和 EditorState 的关联
    /// W5 fix: 将共享 FileSystemService 注入 EditorState
    private func setupMonacoBridge() {
        editorState.monacoBridge = monacoBridge
        // BugFix: 将 MonacoBridge 共享到 AppState，供设置页诊断面板读取
        appState.monacoBridge = monacoBridge
        // W5 fix: 注入共享 FileSystemService 到 EditorState
        editorState.fileSystemService = appState.fileSystemService ?? FileSystemService(rootPath: appState.currentProjectPath)

        // 设置内容变更回调
        monacoBridge.onContentChanged = { content in
            editorState.updateContent(content)
        }

        // 设置保存回调
        monacoBridge.onSave = {
            saveCurrentFile()
        }

        // 加载 Monaco Editor
        monacoBridge.loadEditor()
    }

    /// 打开文件到编辑器
    /// W5 fix: 使用共享 FileSystemService
    private func openFileInEditor(path: String) {
        let fsService = appState.fileSystemService ?? FileSystemService(rootPath: appState.currentProjectPath)
        fsService.setRootPath(appState.currentProjectPath)
        guard let content = try? fsService.readFile(at: path) else {
            appState.showError("无法读取文件: \(path.fileName)")
            return
        }

        editorState.openFile(path: path, content: content)
    }

    /// 保存当前文件
    /// W5 fix: 使用共享 FileSystemService
    /// P1-#11 fix (round 2): 修复保存链路
    /// 根因：monacoBridge.getContent() 异步获取 Monaco 编辑器内容，但 onSave 回调中
    /// 直接调用 saveCurrentFile()，可能因时序问题导致获取到的是旧内容
    /// 修复：在 saveCurrentFile 中先通过 JS 同步获取最新内容，再写入文件
    private func saveCurrentFile() {
        guard let filePath = editorState.activeTab?.filePath else {
            uiLogger.warning("Monaco save: no active tab, skipping save")
            return
        }

        Task {
            // P1-#11 fix (round 2): 先从 Monaco 编辑器获取最新内容
            let content = await monacoBridge.getContent()
            uiLogger.info("Monaco save: getContent returned \(content.count) chars for \(filePath.fileName)")
            
            let fsService = appState.fileSystemService ?? FileSystemService(rootPath: appState.currentProjectPath)
            fsService.setRootPath(appState.currentProjectPath)
            do {
                try fsService.writeFile(at: filePath, content: content)
                // P1-#11 fix (round 2): 同步更新 editorState 的内容，确保 UI 状态一致
                editorState.currentContent = content
                editorState.markSaved()
                uiLogger.info("File saved successfully: \(filePath.fileName) (\(content.count) chars)")
            } catch {
                uiLogger.error("Monaco save failed: \(error.localizedDescription)")
                appState.showError("保存失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Monaco Editor WebView (UIViewRepresentable)

/// WKWebView 容器 — 将 MonacoBridge 的 WKWebView 嵌入 SwiftUI
struct MonacoEditorWebView: UIViewRepresentable {
    @ObservedObject var monacoBridge: MonacoBridge
    @ObservedObject var editorState: EditorState
    @ObservedObject var appState: AppState

    func makeUIView(context: Context) -> WKWebView {
        monacoBridge.createWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Monaco Bridge 通过 evaluateJavaScript 管理 WebView 内容
        // 无需在此处进行手动更新
    }
}