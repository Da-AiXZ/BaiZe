import SwiftUI

/// 权限模式设置视图 — 选择 Agent 的操作确认策略
/// 支持 4 种权限模式：default/acceptEdits/plan/bypass
/// bypass 模式需要用户明确确认开启（安全底线）
struct PermissionSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedMode: PermissionMode = BaizePermission.defaultMode
    @State private var isShowingBypassConfirmation = false

    var body: some View {
        Form {
            // 模式选择
            Section(header: Text("权限模式")) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    PermissionModeRow(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        onSelect: { selectMode(mode) }
                    )
                }
            }

            // 当前模式说明
            Section(header: Text("当前模式说明")) {
                Text(selectedMode.description)
                    .font(.body)
                    .foregroundColor(.secondary)

                Text(modeEffectDescription)
                    .font(.callout)
                    .foregroundColor(.primary.opacity(0.7))
            }

            // 安全提醒
            Section(header: Text("安全提醒")) {
                if selectedMode == .bypass {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("⚠️ 绕过模式下 Agent 将自动执行所有操作，包括文件删除和命令执行。请仅在完全信任的场景中使用。")
                            .font(.callout)
                            .foregroundColor(.red.opacity(0.8))
                    }
                }

                if selectedMode == .plan {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("只读规划模式下 Agent 只分析不执行任何操作。适用于代码审查和影响分析。")
                            .font(.callout)
                            .foregroundColor(.blue.opacity(0.8))
                    }
                }
            }
        }
        .navigationTitle("权限模式")
        .onAppear { selectedMode = appState.permissionMode }
        .alert("确认开启绕过模式", isPresented: $isShowingBypassConfirmation) {
            Button("取消", role: .cancel) { selectedMode = BaizePermission.defaultMode }
            Button("确认开启", role: .destructive) {
                appState.permissionMode = .bypass
            }
        } message: {
            Text("绕过模式将自动执行所有 Agent 操作（包括文件删除、命令执行），不再弹出确认对话框。这可能导致不可逆的数据丢失。确定要开启吗？")
        }
    }

    // MARK: - Mode Selection

    private func selectMode(_ mode: PermissionMode) {
        if mode == .bypass {
            isShowingBypassConfirmation = true
        } else {
            selectedMode = mode
            appState.permissionMode = mode
        }
    }

    /// 当前模式对各操作类型的影响描述
    private var modeEffectDescription: String {
        switch selectedMode {
        case .default:
            return "只读操作（read_file, list_directory 等）→ 自动允许\n" +
                   "写入操作（write_file, edit_file 等）→ 需确认\n" +
                   "执行操作（execute_command, run_node 等）→ 需确认"
        case .acceptEdits:
            return "只读操作 → 自动允许\n" +
                   "文件编辑 → 自动允许\n" +
                   "命令执行 → 需确认"
        case .plan:
            return "所有只读操作 → 自动允许\n" +
                   "所有写入/执行操作 → 直接拒绝"
        case .bypass:
            return "所有操作 → 自动允许（危险命令除外）\n" +
                   "系统级危险操作仍被拒绝（如 rm -rf /）"
        }
    }
}

// MARK: - Permission Mode Row

/// 权限模式选择行
private struct PermissionModeRow: View {
    let mode: PermissionMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 选择指示器
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? Color.baizeAccent : .secondary)
                .font(.system(size: 18))

            // 模式名称 + 描述
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                    .font(.headline)
                Text(mode.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}