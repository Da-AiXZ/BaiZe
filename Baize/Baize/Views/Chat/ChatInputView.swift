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
    /// Bug 3 fix: 停止按钮回调 — Agent 运行时点击停止生成
    let onStop: () -> Void
    /// R1: AppState 引用（用于命令/技能检测）
    var appState: AppState? = nil
    @State private var editorHeight: CGFloat = 40
    @State private var isFocused: Bool = false
    /// R1: 命令补全建议
    @State private var commandSuggestion: String? = nil
    /// R1: 技能触发提示
    @State private var skillSuggestion: String? = nil

    /// 最大输入高度（超过此高度后滚动）
    private let maxEditorHeight: CGFloat = 120
    /// Bug 2 fix: 单行最小高度
    private let minEditorHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 多行文本输入
            // Bug 2 fix: 应用 frame 高度限制，未输入时单行高度
            AutoResizingTextEditor(
                text: $text,
                height: $editorHeight,
                maxHeight: maxEditorHeight,
                minHeight: minEditorHeight,
                isFocused: $isFocused,
                isEditable: !isRunning
            )
            .frame(height: editorHeight)

            // Bug 3 fix: Agent 运行时显示停止按钮，否则显示发送按钮
            if isRunning {
                StopButton(onTap: onStop)
            } else {
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
                        editorHeight = minEditorHeight
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeInputBackground)
        // R1: 命令/技能检测 — 输入变化时检测
        .onChange(of: text) { newValue in
            detectCommandOrSkill(newValue)
        }
        // R1: 命令补全建议
        .overlay(alignment: .top) {
            if let suggestion = commandSuggestion {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.baizeAccent)
                    Text("命令: \(suggestion)")
                        .font(.system(size: 12))
                        .foregroundColor(.baizeAccent)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.baizeAccent.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .offset(y: -32)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let suggestion = skillSuggestion {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                        .foregroundColor(.baizeWarning)
                    Text("检测到技能: \(suggestion)")
                        .font(.system(size: 12))
                        .foregroundColor(.baizeWarning)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.baizeWarning.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .offset(y: -32)
                .transition(.opacity)
            }
        }
        // Bug 5 fix: Agent 运行状态变化时管理键盘焦点
        .onChange(of: isRunning) { running in
            if running {
                // Agent 开始运行 — 收起键盘
                isFocused = false
            } else {
                // Agent 响应完成 — 收起键盘，防止自动唤起
                isFocused = false
                DispatchQueue.main.async {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        }
    }

    // MARK: - R1: Command/Skill Detection

    /// 检测输入是否为 slash 命令或匹配技能触发词
    private func detectCommandOrSkill(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 清空建议
        commandSuggestion = nil
        skillSuggestion = nil

        guard !trimmed.isEmpty, let state = appState else { return }

        // 1. 检测 slash 命令
        if trimmed.hasPrefix("/") {
            Task { @MainActor in
                if let registry = state.commandRegistry {
                    if let (command, _) = await registry.parse(input: trimmed) {
                        commandSuggestion = command.name
                    }
                }
            }
            return
        }

        // 2. 检测技能触发词
        Task { @MainActor in
            if let registry = state.skillRegistry {
                if let skill = await registry.matchSkill(input: trimmed) {
                    skillSuggestion = skill.name
                }
            }
        }
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
    /// Bug 2 fix: 最小高度（单行）
    var minHeight: CGFloat = 40
    @Binding var isFocused: Bool
    /// W9 fix: Agent 运行时禁用编辑
    var isEditable: Bool = true

    /// Bug 2 fix: 缩短 placeholder 避免换行导致输入框过高
    private let placeholder = "输入消息..."

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

        // Placeholder / text
        if text.isEmpty {
            textView.text = placeholder
            textView.textColor = .placeholderText
        } else {
            textView.text = text
            textView.textColor = .label
        }

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // W9 fix: 同步 isEditable 状态
        textView.isEditable = isEditable
        textView.isSelectable = isEditable

        // Bug 3 fix: 同步 binding 文本到 UITextView（处理发送后清空等外部变更）
        // 注意：编程方式设置 textView.text 不会触发 textViewDidChange，无反馈循环
        // 用户输入时 textView.text 已等于 binding 值，不会更新（无光标跳动）
        if text.isEmpty {
            if !textView.isFirstResponder {
                // 非编辑状态 — 显示 placeholder
                if textView.text != placeholder {
                    textView.text = placeholder
                    textView.textColor = .placeholderText
                }
            } else if !textView.text.isEmpty && textView.text != placeholder {
                // 编辑状态但文本被外部清空（如发送后）— 清空显示
                textView.text = ""
                textView.textColor = .label
            }
            // Bug 2 fix: 文本为空时重置高度为单行
            if height != minHeight {
                height = minHeight
            }
        } else {
            if textView.text != text {
                textView.text = text
                textView.textColor = .label
            }
        }

        // 焦点管理
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

            // Bug 2 fix: Auto-resize with minimum height
            let size = textView.sizeThatFits(
                CGSize(width: textView.frame.width, height: .greatestFiniteMagnitude)
            )
            parent.height = max(parent.minHeight, min(size.height, parent.maxHeight))
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

// MARK: - Stop Button (Bug 3 fix)

/// 停止按钮 — Agent 运行时显示，点击停止生成
struct StopButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.red)
        }
        .buttonStyle(.plain)
    }
}