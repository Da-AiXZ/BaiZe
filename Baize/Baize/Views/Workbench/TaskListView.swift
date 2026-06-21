import SwiftUI

/// 任务清单视图 — 展示 TodoWrite 工具输出的任务列表
@MainActor
struct TaskListView: View {
    let todoItems: [TodoItem]

    var body: some View {
        if todoItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("暂无任务")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(todoItems, id: \.id) { item in
                    todoRow(item)
                }
            }
        }
    }

    /// 单个任务行
    private func todoRow(_ item: TodoItem) -> some View {
        HStack(spacing: 10) {
            // 状态图标
            statusIcon(item.status)

            // 任务内容
            Text(item.content)
                .font(.system(size: 13))
                .foregroundColor(item.status == "completed" ? .secondary : .primary)
                .strikethrough(item.status == "completed", color: .secondary)

            Spacer()

            // 状态标签
            statusBadge(item.status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.baizeCardBackground.opacity(0.5))
        .cornerRadius(8)
    }

    /// 状态图标
    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.baizeSuccess)
        case "in_progress":
            ProgressView()
                .scaleEffect(0.6)
        default:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        }
    }

    /// 状态徽章
    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status {
        case "completed": label = "完成"; color = .baizeSuccess
        case "in_progress": label = "进行中"; color = .baizeAccent
        default: label = "待办"; color = .secondary
        }
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }
}
