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

            // Bug 2 fix: 关闭按钮始终显示（不限 isActive），增大触摸区域
            // 用 zIndex + contentShape 分离关闭按钮和 Tab 点击区域，避免手势冲突
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)  // 20x20 图标区域
                    .background(
                        Circle()
                            .fill(Color.secondary.opacity(isActive ? 0.15 : 0.0))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())  // 限制点击区域为圆形，避免误触
            .frame(width: 24, height: 24)  // 24x24 触摸目标
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