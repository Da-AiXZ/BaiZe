import SwiftUI

/// Memory 设置 — 自动提取开关 + 频率配置
@MainActor
struct MemorySettingsView: View {
    @ObservedObject var appState: AppState

    @State private var autoExtractionEnabled: Bool = true
    @State private var memoryCount: Int = 0

    var body: some View {
        Form {
            Section("自动记忆提取") {
                Toggle("自动提取记忆", isOn: $autoExtractionEnabled)
                    .onChange(of: autoExtractionEnabled) { enabled in
                        MemoryExtractor.setAutoExtraction(enabled: enabled)
                    }

                Text("开启后，每轮对话结束时 AI 会自动从对话中提取值得记忆的信息（偏好、决策、待办等），下次对话时自动注入相关记忆。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("已存储记忆") {
                HStack {
                    Text("用户级记忆")
                    Spacer()
                    Text("\(memoryCount) 条")
                        .foregroundColor(.secondary)
                }

                Button(action: { loadMemoryCount() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                }
            }

            Section("管理") {
                Button(role: .destructive, action: { clearMemories() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("清除所有记忆")
                    }
                }
            }
        }
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            autoExtractionEnabled = MemoryExtractor.isAutoExtractionEnabled()
            loadMemoryCount()
        }
    }

    /// 加载记忆数量
    private func loadMemoryCount() {
        guard let store = appState.memoryStore else { return }
        Task {
            let memories = await store.getMemories(scope: .user)
            await MainActor.run { self.memoryCount = memories.count }
        }
    }

    /// 清除所有记忆
    /// Bug #12 fix: 清理所有 scope（user/project/team），而非仅 user scope
    private func clearMemories() {
        guard appState.memoryStore != nil else { return }
        Task {
            let fm = FileManager.default
            // 清除所有 scope 的记忆文件
            let memoryDirs: [(scope: String, dir: String)] = [
                ("user", BaizePath.userMemoryDir),
                ("project", BaizePath.projectMemoryDir),
                ("team", BaizePath.teamMemoryDir)
            ]
            for (_, dir) in memoryDirs {
                let filePath = (dir as NSString).appendingPathComponent("memories.jsonl")
                if fm.fileExists(atPath: filePath) {
                    try? fm.removeItem(atPath: filePath)
                }
            }
            await MainActor.run {
                self.memoryCount = 0
            }
        }
    }
}
