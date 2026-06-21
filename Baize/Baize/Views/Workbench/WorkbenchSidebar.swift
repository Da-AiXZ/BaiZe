import SwiftUI

/// 工作台侧栏容器 — 5 个可折叠区域
/// R3 重构：替代原 TabView 的 Git Tab + Dashboard Tab
/// 横屏时作为 HSplitView 右侧面板（width: 360），竖屏时作为底部抽屉
@MainActor
struct WorkbenchSidebar: View {
    @ObservedObject var appState: AppState

    @State private var expandedSections: Set<WorkbenchSection> = [.taskList, .fileChanges]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 任务清单
                workbenchSection(.taskList, title: "任务清单", icon: "checklist") {
                    TaskListView(todoItems: appState.todoItems)
                }

                // 文件改动
                workbenchSection(.fileChanges, title: "文件改动", icon: "doc.on.doc") {
                    FileChangesPanel(appState: appState)
                }

                // Git 状态
                workbenchSection(.gitStatus, title: "Git 状态", icon: "arrow.triangle.branch") {
                    if let gitVM = appState.gitViewModel {
                        GitStatusView(viewModel: gitVM)
                    } else {
                        Text("Git 未初始化")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }

                // 命令输出
                workbenchSection(.commandOutput, title: "命令输出", icon: "terminal") {
                    CommandOutputView(appState: appState)
                }

                // Diff 视图
                workbenchSection(.diffView, title: "代码差异", icon: "doc.text.magnifyingglass") {
                    DiffViewer(appState: appState)
                }
            }
        }
        .background(Color.baizeChatBackground)
    }

    /// 可折叠区域
    @ViewBuilder
    private func workbenchSection<Content: View>(
        _ section: WorkbenchSection,
        title: String,
        icon: String,
        content: @escaping @ViewBuilder () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedSections.contains(section) },
                set: { isExpanded in
                    if isExpanded {
                        expandedSections.insert(section)
                    } else {
                        expandedSections.remove(section)
                    }
                }
            )
        ) {
            content()
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.baizeAccent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// 工作台区域枚举
enum WorkbenchSection: String, Hashable {
    case taskList
    case fileChanges
    case gitStatus
    case commandOutput
    case diffView
}
