import SwiftUI
import WebKit

/// Monaco Editor WKWebView ↔ Swift 双向桥接
/// 通过 WKScriptMessageHandler 接收 JS 事件（内容变更、保存）
/// 通过 evaluateJavaScript 向 Monaco 发送指令（打开文件、设置语言等）
/// 必须在 MainActor 上运行（WKWebView 操作要求主线程）
@MainActor
class MonacoBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    // MARK: - Properties

    /// WKWebView 实例（Monaco Editor 宿主）
    private var webView: WKWebView?

    /// 内容变更回调
    var onContentChanged: ((String) -> Void)?

    /// 保存回调
    var onSave: (() -> Void)?

    /// 当前打开的文件路径
    @Published var currentFilePath: String?

    /// 当前文件内容（从 JS 同步回来的最新版本）
    @Published var currentContent: String = ""

    /// Monaco Editor 是否已加载完成
    @Published var isEditorLoaded: Bool = false

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - WKWebView Configuration

    /// 创建配置好的 WKWebView
    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()

        // 注册消息处理器
        let contentController = config.userContentController
        contentController.add(self, name: "contentChanged")
        contentController.add(self, name: "save")
        contentController.add(self, name: "editorReady")
        contentController.add(self, name: "error")

        // 允许内联媒体播放
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Color.baizeEditorBackground)
        webView.scrollView.isScrollEnabled = true

        self.webView = webView
        return webView
    }

    // MARK: - Editor Loading

    /// 加载 Monaco Editor HTML 页面
    /// 从 App Bundle 加载 monaco-editor/index.html，允许读取整个 monaco-editor 目录
    func loadEditor() {
        guard let webView = webView else { return }

        // 从 App Bundle 加载 Monaco Editor 资源
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: BaizePath.monacoResources) {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            // allowingReadAccessTo 设为 monaco-editor 目录，使 Monaco AMD loader 能加载 min/vs/ 下的文件
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            uiLogger.info("Loading Monaco Editor from bundle: \(htmlPath)")
        } else {
            uiLogger.error("Monaco Editor resources not found in bundle — index.html missing from \(BaizePath.monacoResources)")
        }
    }

    // MARK: - Editor Operations

    /// 打开文件 — 设置 Monaco Editor 内容和语言模式
    /// 等待 isEditorLoaded 后再调用 JS，确保 Monaco 实例已就绪
    /// - Parameters:
    ///   - path: 文件路径（用于标识）
    ///   - content: 文件内容
    func openFile(path: String, content: String) {
        currentFilePath = path
        currentContent = content

        let language = languageForFile(path: path)
        let escapedContent = escapeForJavaScript(content)

        // 如果编辑器尚未加载，延迟执行
        if !isEditorLoaded {
            uiLogger.debug("Monaco: editor not ready, deferring openFile for \(path.fileName)")
            Task { @MainActor in
                // 等待编辑器加载完成，最多 5 秒
                for _ in 0..<50 {
                    if self.isEditorLoaded { break }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
                self.evaluateJavaScript("monacoOpenFile('\(escapedContent)', '\(language)')")
            }
        } else {
            evaluateJavaScript("monacoOpenFile('\(escapedContent)', '\(language)')")
        }
        uiLogger.info("Monaco: opened file \(path.fileName) with language \(language)")
    }

    /// 获取 Monaco Editor 当前内容（异步调用 JS）
    /// - Returns: 当前编辑器内容字符串
    func getContent() async -> String {
        guard let webView = webView else { return currentContent }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("monacoGetContent()") { result, error in
                if let error = error {
                    uiLogger.error("Monaco getContent error: \(error.localizedDescription)")
                    continuation.resume(returning: self.currentContent)
                } else if let content = result as? String {
                    self.currentContent = content
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(returning: self.currentContent)
                }
            }
        }
    }

    /// 设置 Monaco Editor 内容
    func setContent(content: String) {
        currentContent = content
        let escaped = escapeForJavaScript(content)
        evaluateJavaScript("monacoSetContent('\(escaped)')")
    }

    /// 设置 Monaco Editor 语言模式
    func setLanguage(language: String) {
        evaluateJavaScript("monacoSetLanguage('\(language)')")
        uiLogger.debug("Monaco: set language to \(language)")
    }

    /// 设置 Monaco Editor 主题
    /// - Parameter themeName: 主题名称（baize-cyberpunk, vs-dark, vs, hc-black）
    func setTheme(_ themeName: String) {
        evaluateJavaScript("monacoSetTheme('\(themeName)')")
        uiLogger.debug("Monaco: set theme to \(themeName)")
    }

    /// 获取 Monaco Editor 支持的语言列表
    /// - Returns: JSON 字符串数组，如 ["javascript","python","swift",...]
    func getLanguages() async -> String {
        guard let webView = webView else { return "[]" }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("monacoGetLanguages()") { result, error in
                if let error = error {
                    uiLogger.error("Monaco getLanguages error: \(error.localizedDescription)")
                    continuation.resume(returning: "[]")
                } else if let languages = result as? String {
                    continuation.resume(returning: languages)
                } else {
                    continuation.resume(returning: "[]")
                }
            }
        }
    }

    /// 跳转到指定行号
    /// - Parameter line: 行号（1-based）
    func goToLine(line: Int) {
        evaluateJavaScript("monacoGoToLine(\(line))")
        uiLogger.debug("Monaco: go to line \(line)")
    }

    /// 在编辑器中搜索
    /// - Parameter query: 搜索关键词
    func search(query: String) {
        let escaped = escapeForJavaScript(query)
        evaluateJavaScript("monacoSearch('\(escaped)')")
        uiLogger.debug("Monaco: search for '\(query)'")
    }

    /// 触发编辑器重新布局（例如 iPad 旋转后调用）
    func layout() {
        evaluateJavaScript("monacoLayout()")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body

        switch message.name {
        case "contentChanged":
            if let content = body as? String {
                Task { @MainActor in
                    self.currentContent = content
                    self.onContentChanged?(content)
                }
            }

        case "save":
            Task { @MainActor in
                self.onSave?()
            }

        case "editorReady":
            Task { @MainActor in
                self.isEditorLoaded = true
                uiLogger.info("Monaco Editor loaded and ready")
            }

        case "error":
            if let errorMsg = body as? String {
                uiLogger.error("Monaco JS error: \(errorMsg)")
            }

        default:
            break
        }
    }

    // MARK: - Private Helpers

    /// 执行 JavaScript（异步，错误日志）
    private func evaluateJavaScript(_ script: String) {
        guard let webView = webView else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                uiLogger.error("Monaco JS eval error: \(error.localizedDescription)")
            }
        }
    }

    /// 根据文件扩展名推断 Monaco 语言 ID
    private func languageForFile(path: String) -> String {
        let ext = path.fileExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "typescript"
        case "jsx": return "javascript"
        case "json": return "json"
        case "md": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        case "yaml", "yml": return "yaml"
        case "xml": return "xml"
        case "sh", "bash": return "shell"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx": return "cpp"
        case "java": return "java"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "php": return "php"
        case "sql": return "sql"
        case "r": return "r"
        case "dockerfile": return "dockerfile"
        case "lua": return "lua"
        case "kt", "kts": return "kotlin"
        case "scala": return "scala"
        case "pl", "pm": return "perl"
        case "dart": return "dart"
        case "objc": return "objective-c"
        case "m", "mm": return "objective-c"
        default: return "plaintext"
        }
    }

    /// 转义字符串用于 JavaScript 单引号字符串
    private func escapeForJavaScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - WKNavigationDelegate

extension MonacoBridge {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            uiLogger.info("Monaco WebView navigation completed")
            // Note: isEditorLoaded is set by JS editorReady message, not here
            // because AMD require() is async — the page loads first, then Monaco initializes
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            uiLogger.error("Monaco WebView navigation failed: \(error.localizedDescription)")
            isEditorLoaded = false
        }
    }
}
