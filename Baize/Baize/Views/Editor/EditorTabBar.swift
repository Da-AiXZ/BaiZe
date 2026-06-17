import SwiftUI

/// 编辑器多 Tab 栏 — 显示打开的文件 Tab，支持切换和关闭
struct EditorTabBar: View {
    @ObservedObject var editorState: EditorState

    var body: some View {
        HStack(spacing: 0) {
            // Tab 列表
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(editorState.openTabs) { tab in
                        EditorTabItem(
                            tab: tab,
                            isActive: editorState.activeTab?.id == tab.id,
                            hasUnsavedChanges: editorState.hasUnsavedChanges && editorState.activeTab?.id == tab.id,
                            onTap: { editorState.switchToTab(tab) },
                            onClose: { editorState.closeTab(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // 当前光标位置
            Text(editorState.cursorPosition.description)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.trailing, 8)
        }
        .padding(.vertical, 4)
        .background(Color.baizeTabBarBackground)
    }
}

// MARK: - Editor Tab Item

/// 单个文件 Tab — 显示文件名 + 关闭按钮 + 未保存标记
struct EditorTabItem: View {
    let tab: EditorTab
    let isActive: Bool
    let hasUnsavedChanges: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // 文件类型图标
            Image(systemName: fileIcon)
                .font(.system(size: 11))
                .foregroundColor(isActive ? Color.baizeAccent : .secondary)

            // 文件名
            Text(tab.fileName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            // 未保存修改标记（小圆点）
            if hasUnsavedChanges {
                Circle()
                    .fill(Color.baizeAccent)
                    .frame(width: 6, height: 6)
            }

            // 关闭按钮（仅激活 Tab 显示）
            if isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.baizeTabActive : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var fileIcon: String {
        switch tab.fileExtension {
        case "swift": return "swift"
        case "py": return "doc.plaintext"
        case "tsx", "ts": return "doc.richtext"
        case "js": return "doc.richtext"
        case "json": return "doc.text"
        case "md": return "doc.text.fill"
        case "html": return "doc"
        default: return "doc"
        }
    }
}