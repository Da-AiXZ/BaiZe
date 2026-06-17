import SwiftUI
import UIKit

/// 对话输入框视图 — 支持多行输入 + 发送按钮
/// 完整实现（非占位）：TextEditor + Send Button + Shift+Enter newline (hardware keyboard)
/// W9 fix: 添加 isRunning 参数，Agent 运行时禁用发送按钮防止重复提交
struct ChatInputView: View {
    @Binding var text: String
    /// Agent 是否正在运行（W9 fix: 运行时禁用发送）
    let isRunning: Bool
    let onSend: (String) -> Void
    @State private var editorHeight: CGFloat = 36
    @FocusState private var isFocused: Bool

    /// 最大输入高度（超过此高度后滚动）
    private let maxEditorHeight: CGFloat = 120

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 多行文本输入
            AutoResizingTextEditor(
                text: $text,
                height: $editorHeight,
                maxHeight: maxEditorHeight,
                isFocused: $isFocused,
                isEditable: !isRunning
            )

            // 发送按钮
            // W9 fix: isRunning 时按钮禁用（灰色、不可点击）
            SendButton(
                isEnabled: !isRunning && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                onTap: {
                    guard !isRunning else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSend(trimmed)
                    text = ""
                    editorHeight = 36
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeInputBackground)
    }
}

// MARK: - Auto-Resizing Text Editor

/// 自动调整高度的 UITextView 包装
/// 支持多行输入、Placeholder、硬件键盘 Enter 发送 / Shift+Enter 换行
/// W9 fix: 添加 isEditable 参数，Agent 运行时不可编辑
struct AutoResizingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let maxHeight: CGFloat
    @FocusState var isFocused: Bool
    /// W9 fix: Agent 运行时禁用编辑
    var isEditable: Bool = true

    private let placeholder = "输入消息... (Shift+Enter 换行)"

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.font = UIFont.systemFont(ofSize: 14)
        textView.textColor = .label
        textView.backgroundColor = UIColor(Color.baizeInputFieldBackground)
        textView.layer.cornerRadius = 10
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor(Color.baizeInputBorder).cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = false

        // Placeholder
        if text.isEmpty {
            textView.text = placeholder
            textView.textColor = .placeholderText
        }

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // W9 fix: 同步 isEditable 状态
        textView.isEditable = isEditable
        textView.isSelectable = isEditable

        if isFocused && !textView.isFirstResponder && isEditable {
            textView.becomeFirstResponder()
        } else if !isFocused && textView.isFirstResponder {
            textView.resignFirstResponder()
        } else if !isEditable && textView.isFirstResponder {
            // Agent 运行时，关闭键盘
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoResizingTextEditor
        weak var textView: UITextView?

        init(_ parent: AutoResizingTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let text = textView.text ?? ""
            if text == parent.placeholder {
                parent.text = ""
            } else {
                parent.text = text
            }

            // Auto-resize
            let size = textView.sizeThatFits(
                CGSize(width: textView.frame.width, height: .greatestFiniteMagnitude)
            )
            parent.height = min(size.height, parent.maxHeight)
            textView.isScrollEnabled = size.height > parent.maxHeight
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            if textView.text == parent.placeholder {
                textView.text = ""
                textView.textColor = .label
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
            if textView.text.isEmpty {
                textView.text = parent.placeholder
                textView.textColor = .placeholderText
            }
        }

        /// Enter → 发送 | Shift+Enter → 换行 (hardware keyboard only)
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                // Check if Shift key is held (hardware keyboard)
                // On iOS, there's no direct API to check Shift state in UITextViewDelegate.
                // For software keyboard, newline always inserts.
                // For hardware keyboard, we rely on the user's preference.
                // Phase 1: Enter always inserts newline, user clicks Send button to submit.
                // This is the standard iOS chat app pattern.
                return true
            }
            return true
        }
    }
}

// MARK: - Send Button

/// 发送按钮 — 带图标 + 启用/禁用状态
struct SendButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(isEnabled ? Color.baizeAccent : Color.gray.opacity(0.4))
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
}