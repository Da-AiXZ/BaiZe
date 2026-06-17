import SwiftUI
import WebKit

/// Monaco Editor WKWebView ↔ Swift 双向桥接
/// 通过 WKScriptMessageHandler 接收 JS 事件（内容变更、保存）
/// 通过 evaluateJavaScript 向 Monaco 发送指令（打开文件、设置语言等）
/// 必须在 MainActor 上运行（WKWebView 操作要求主线程）
@MainActor
class MonacoBridge: NSObject, ObservableObject {

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

    // MARK: - Editor Operations

    /// 加载 Monaco Editor HTML 页面
    func loadEditor() {
        guard let webView = webView else { return }

        // 从 App Bundle 加载 Monaco Editor 资源
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: BaizePath.monacoResources) {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            uiLogger.info("Loading Monaco Editor from bundle: \(htmlPath)")
        } else {
            // Phase 1: 如果 Monaco 资源尚未嵌入 Bundle，加载占位 HTML
            loadPlaceholderHTML()
            uiLogger.warning("Monaco Editor resources not found, loading placeholder")
        }
    }

    /// 打开文件 — 设置 Monaco Editor 内容和语言模式
    /// - Parameters:
    ///   - path: 文件路径（用于标识）
    ///   - content: 文件内容
    func openFile(path: String, content: String) {
        currentFilePath = path
        currentContent = content

        let language = languageForFile(path: path)
        let escapedContent = escapeForJavaScript(content)

        evaluateJavaScript("monacoOpenFile('\(escapedContent)', '\(language)')")
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

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
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

    /// 加载 Phase 1 占位 HTML（Monaco 资源尚未嵌入时的回退）
    private func loadPlaceholderHTML() {
        guard let webView = webView else { return }

        let placeholderHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { margin: 0; padding: 0; background: #1E1E1E; color: #D4D4D4; }
                #editor { width: 100%; height: 100vh; font-family: 'Menlo', monospace; }
                .placeholder { padding: 40px; text-align: center; }
                .placeholder h2 { color: #4A9EFF; }
                .placeholder p { color: #888; }
            </style>
        </head>
        <body>
            <div id="editor">
                <div class="placeholder">
                    <h2>Monaco Editor</h2>
                    <p>Phase 1 Placeholder — Monaco Editor resources will be embedded in Phase 2</p>
                </div>
            </div>
            <script>
                // Placeholder JavaScript API for Monaco Bridge
                function monacoOpenFile(content, language) {
                    document.getElementById('editor').innerText = content;
                    window.webkit.messageHandlers.editorReady.postMessage('');
                }
                function monacoGetContent() {
                    return document.getElementById('editor').innerText;
                }
                function monacoSetContent(content) {
                    document.getElementById('editor').innerText = content;
                }
                function monacoSetLanguage(language) {
                    // Placeholder — no language support yet
                }
                window.webkit.messageHandlers.editorReady.postMessage('');
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(placeholderHTML, baseURL: nil)
    }
}

// MARK: - WKNavigationDelegate

extension MonacoBridge: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            uiLogger.info("Monaco WebView navigation completed")
            isEditorLoaded = true
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            uiLogger.error("Monaco WebView navigation failed: \(error.localizedDescription)")
            isEditorLoaded = false
        }
    }
}