import Foundation

/// Bug 6 fix: 流式文本缓冲区 — 解决 streamingText 拼接 O(n²) 性能问题
/// textDelta 累积到非 @Published 的 buffer（不触发 UI 重绘），
/// 定时 flush 到 @Published displayedText（每 80ms 触发一次 UI 重绘）
/// 这样 10000 字生成时，@State 更新频率从「每个 chunk」降到「每 80ms 一次」
///
/// T01-3 fix: buffer 从 String 改为 [String]，append 操作从 O(n) 拷贝降为 O(1)
/// 仅在 flush 时调用 joined() 拼接，将 O(n²) 累积降为 O(n) 总计
@MainActor
final class StreamingTextBuffer: ObservableObject {
    /// 非 Published 的累积缓冲区 — 不触发 UI 重绘
    /// T01-3 fix: 使用 [String] 替代 String，append 为 O(1) 而非 O(n) 拷贝
    private var buffer: [String] = []

    /// 定时 flush 到 displayedText — 触发 UI 重绘（每 80ms 一次）
    @Published var displayedText: String = ""

    /// flush 定时器
    private var flushTimer: DispatchSourceTimer?

    /// flush 间隔（秒）
    /// P1-#1 fix: 从 80ms 降到 16ms（60fps），实现逐字流畅输出
    /// 之前 80ms 导致文本一批批出现而非逐字流式
    private let flushInterval: TimeInterval = 0.016

    /// 追加文本到缓冲区（不触发 UI 重绘）
    /// T01-3 fix: O(1) append 替代 O(n) 字符串拼接
    func append(_ text: String) {
        buffer.append(text)
        startTimerIfNeeded()
    }

    /// 立即 flush 缓冲区到 displayedText（触发一次 UI 重绘）
    func flush() {
        stopTimer()
        displayedText = buffer.joined()
    }

    /// 重置缓冲区（清空 buffer + displayedText）
    func reset() {
        stopTimer()
        buffer = []
        displayedText = ""
    }

    /// 获取当前完整文本（不触发 UI 重绘）
    var fullText: String {
        buffer.joined()
    }

    /// 缓冲区是否为空
    var isEmpty: Bool {
        buffer.isEmpty
    }

    private func startTimerIfNeeded() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    deinit {
        // 直接 cancel，不调 stopTimer()（避免 @MainActor 隔离问题）
        flushTimer?.cancel()
    }
}
