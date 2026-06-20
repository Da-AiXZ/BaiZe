import SwiftUI

// MARK: - Session List View (P1-1)

/// 会话列表视图 — 显示已保存的对话，支持选择恢复或新建
struct SessionListView: View {
    let sessions: [ConversationSession]
    let currentSessionId: UUID?
    let onSelect: (ConversationSession) -> Void
    let onNewSession: () -> Void

    var body: some View {
        NavigationView {
            List {
                // 顶部新建会话按钮
                Section {
                    Button(action: onNewSession) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.baizeAccent)
                            Text("新建会话")
                                .foregroundColor(.baizeAccent)
                        }
                    }
                }

                // 已保存的会话列表
                Section {
                    if sessions.isEmpty {
                        Text("暂无历史会话")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            SessionRow(
                                session: session,
                                isCurrent: session.id == currentSessionId
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(session)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Session Row

/// 单个会话行 — 标题 + 相对时间 + 消息数
struct SessionRow: View {
    let session: ConversationSession
    let isCurrent: Bool

    /// 会话标题：优先用首条用户消息前 30 字，否则用 session.title
    private var displayTitle: String {
        for message in session.messages {
            if case .user(let text) = message {
                let firstLine = text.split(separator: "\n").first ?? ""
                let title = String(firstLine.prefix(30))
                return title.isEmpty ? session.title : title
            }
        }
        return session.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.baizeSuccess)
                }
                Text(displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.baizeTextPrimary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(session.updatedAt.chatTimestamp)
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)

                Text("\(session.messages.count) 条消息")
                    .font(.caption2)
                    .foregroundColor(.baizeTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
