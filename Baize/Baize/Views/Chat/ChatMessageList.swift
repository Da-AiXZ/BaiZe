import SwiftUI

// MARK: - Chat Message List

/// 消息滚动列表
/// Bug 4 fix: 修复自动滚底逻辑 + 添加悬浮"滚到底"按钮
/// T01-1 fix: onChange(of: messages.count) 不再强制覆盖 isTrackingBottom，
///            仅在用户已处于底部时才自动滚动，尊重用户上滑阅读意图
struct ChatMessageList: View {
    let messages: [DisplayMessage]
    let streamingText: String
    let isStreaming: Bool

    // Bug 4 fix: 滚动位置追踪
    @State private var contentHeight: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    // Bug 1 fix: 流式输出滚动节流 — 距上次滚动 < 100ms 跳过，避免高频 UI 重绘
    @State private var lastScrollTime: Date = .distantPast

    // Bug 4 fix: 滚动跟踪状态 — 用户上滑时停止自动跟踪，点按钮恢复
    @State private var isTrackingBottom: Bool = true
    // Bug 4 fix: 标记编程式滚动，防止 onPreferenceChange 误判为用户上滑
    @State private var isProgrammaticScroll: Bool = false

    /// 是否显示"滚到底"按钮 — 当用户上滑且不在底部时显示
    private var showScrollToBottomButton: Bool {
        let maxScrollOffset = contentHeight - scrollViewHeight
        return maxScrollOffset > 120 && scrollOffset < maxScrollOffset - 120
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // 流式文本（Agent 正在输出）
                        if isStreaming && !streamingText.isEmpty {
                            StreamingTextBubble(text: streamingText)
                                .id("streaming")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Bug 4 fix: 追踪内容高度和滚动偏移
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ChatContentHeightKey.self, value: geo.size.height)
                                .preference(key: ChatScrollOffsetKey.self,
                                            value: -geo.frame(in: .named("chatScroll")).minY)
                        }
                    )
                }
                .coordinateSpace(name: "chatScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatScrollViewHeightKey.self, value: geo.size.height)
                    }
                )
                // Bug 5 fix: 隔离动画范围 — .transaction 阻止动画传导到 ScrollView 内部长内容。
                // 焦点切换/侧栏滑出时容器 frame 仍平滑过渡（由 withAnimation / 系统动画驱动），
                // 但 ScrollView 内部的 LazyVStack 长内容不参与动画，直接跳到最终宽度布局，
                // 避免动画期间每帧全量重绘导致的卡顿和内容抽动/消失。
                // 注意：scrollToBottom 的 proxy.scrollTo 使用独立 transaction，不受此影响。
                // 滚到底按钮在 ZStack 中与 ScrollView 平级，也不受此 .transaction 影响。
                .transaction { t in
                    t.animation = nil
                }
                .onPreferenceChange(ChatContentHeightKey.self) { contentHeight = $0 }
                .onPreferenceChange(ChatScrollViewHeightKey.self) { scrollViewHeight = $0 }
                .onPreferenceChange(ChatScrollOffsetKey.self) { offset in
                    scrollOffset = offset
                    // Bug 4 fix: 检测用户上滑离开底部 → 打断自动跟踪
                    // 编程式滚动期间忽略（防止 scrollToBottom 触发误判）
                    guard !isProgrammaticScroll else { return }
                    let maxOffset = contentHeight - scrollViewHeight
                    if maxOffset > 120 && offset < maxOffset - 120 {
                        isTrackingBottom = false
                    }
                }
                .onChange(of: messages.count) { _ in
                    // T01-1 fix: 不再强制覆盖 isTrackingBottom = true
                    // 仅在用户已处于底部跟踪状态时才自动滚动，尊重用户上滑阅读意图
                    // isTrackingBottom 仅在以下场景设为 true：
                    //   ① 用户主动发消息（sendMessage 时用户通常在底部）
                    //   ② 点击"滚到底"按钮
                    guard isTrackingBottom else { return }
                    scrollToBottom(proxy: proxy, force: true)
                }
                .onChange(of: streamingText) { _ in
                    // Bug 4 fix: 仅在跟踪底部时才自动滚动，用户上滑后不打断
                    guard isTrackingBottom else { return }
                    // Bug 1 fix: 流式输出时节流滚动（force=false，距上次 < 100ms 跳过）
                    scrollToBottom(proxy: proxy)
                }

                // Bug 4 fix: 悬浮"滚到底"按钮
                if showScrollToBottomButton {
                    Button(action: {
                        // Bug 4 fix: 点击按钮恢复跟踪 + 强制滚动
                        isTrackingBottom = true
                        scrollToBottom(proxy: proxy, force: true)
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(Color.baizeAccent)
                            .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                            .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    /// Bug 1 fix: 滚动到底部 — 流式输出时去动画 + 节流，非流式时带动画
    /// Bug 4 fix: 设置 isProgrammaticScroll 防止 onPreferenceChange 误判为用户上滑
    /// - Parameter force: true 时跳过节流（用于 messages.count 变化、用户点击按钮）
    /// - 流式输出时：去动画（proxy.scrollTo 直接调用），force=false 时距上次滚动 < 100ms 跳过
    /// - 非流式时：带 withAnimation(.easeOut) 动画
    private func scrollToBottom(proxy: ScrollViewProxy, force: Bool = false) {
        if isStreaming {
            // 流式输出时节流（除非 force）
            if !force {
                let now = Date()
                if now.timeIntervalSince(lastScrollTime) < 0.1 {
                    return
                }
                lastScrollTime = now
            }
            // Bug 4 fix: 标记编程式滚动，防止 onPreferenceChange 误判
            isProgrammaticScroll = true
            // 流式输出时去动画，直接滚动
            if !streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastId = messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
            // 短暂延迟后解除标记
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isProgrammaticScroll = false
            }
        } else {
            // Bug 4 fix: 标记编程式滚动
            isProgrammaticScroll = true
            // 非流式时带动画
            withAnimation(.easeOut(duration: 0.3)) {
                if let lastId = messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            // 动画结束后解除标记
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isProgrammaticScroll = false
            }
        }
    }
}

// MARK: - Scroll Preference Keys (Bug 4 fix)

/// 内容高度偏好键
fileprivate struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// ScrollView 可视高度偏好键
fileprivate struct ChatScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 滚动偏移偏好键
fileprivate struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
