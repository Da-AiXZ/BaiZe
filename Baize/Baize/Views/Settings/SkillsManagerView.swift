import SwiftUI

/// 技能管理 — 列出已安装技能，开关启用
@MainActor
struct SkillsManagerView: View {
    @ObservedObject var appState: AppState

    @State private var skills: [Skill] = []
    @State private var disabledSkills: Set<String> = []

    var body: some View {
        Group {
            if skills.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无已安装技能")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("技能位于 Resources/skills/ 或 .baize/skills/ 目录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(skills, id: \.name) { skill in
                        skillRow(skill)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("技能管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { loadSkills() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { loadSkills() }
    }

    /// 技能行
    private func skillRow(_ skill: Skill) -> some View {
        let isDisabled = disabledSkills.contains(skill.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { !isDisabled },
                    set: { enabled in
                        if enabled {
                            disabledSkills.remove(skill.name)
                        } else {
                            disabledSkills.insert(skill.name)
                        }
                    }
                ))
                .labelsHidden()
            }

            // 触发词标签
            if !skill.triggers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(skill.triggers, id: \.self) { trigger in
                            Text(trigger)
                                .font(.system(size: 10))
                                .foregroundColor(.baizeAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.baizeAccent.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            // 来源标签
            HStack(spacing: 6) {
                Text(sourceLabel(skill.source))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("优先级: \(skill.priority)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 加载技能列表
    private func loadSkills() {
        guard let registry = appState.skillRegistry else { return }
        Task {
            let loaded = await registry.listSkills()
            await MainActor.run { self.skills = loaded }
        }
    }

    /// 来源标签文本
    private func sourceLabel(_ source: SkillSource) -> String {
        switch source {
        case .bundled: return "内置"
        case .user: return "用户"
        case .project: return "项目"
        }
    }
}
