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
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    /// 更新视图控制器（无需操作）
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
