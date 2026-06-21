import SwiftUI
import UIKit

// MARK: - Share Sheet (T05: #16 导出对话)

/// iOS Share Sheet 包装器 — 将 UIActivityViewController 暴露给 SwiftUI
/// 用于分享导出的对话文件（Markdown / 纯文本 / JSON）
///
/// 用法：
/// ```swift
/// .sheet(isPresented: $showShareSheet) {
///     ShareSheet(items: [fileURL])
/// }
/// ```
struct ShareSheet: UIViewControllerRepresentable {
    /// 分享内容 — 可以是 URL（文件）、String（文本）等
    let items: [Any]

    /// 创建 UIActivityViewController
    /// Bug 6 fix: 检查 items 非空，避免空 ShareSheet 导致黑屏
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // 过滤掉无效的 items（如不存在的文件 URL）
        let validItems = items.filter { item in
            if let url = item as? URL {
                return FileManager.default.fileExists(atPath: url.path)
            }
            if let str = item as? String {
                return !str.isEmpty
            }
            return true
        }

        // 如果没有有效 items，传入一个提示文本而非空数组（避免 UIActivityViewController 黑屏）
        let shareItems = validItems.isEmpty
            ? ["导出失败：文件不存在"] as [Any]
            : validItems

        let controller = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)

        // Bug 6 fix: 在 iPad 上设置 popoverPresentationController 避免黑屏/崩溃
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView()
            popover.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2,
                                        y: UIScreen.main.bounds.height / 2,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        return controller
    }

    /// 更新视图控制器（无需操作）
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
