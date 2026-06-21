import Foundation

// MARK: - Skill Source

/// 技能来源 — 标识技能安装位置
/// 三级目录：bundled（App 内置）→ user（用户安装，跨项目）→ project（项目特定）
enum SkillSource: Sendable {
    /// App Bundle 内置技能（Resources/skills/*/SKILL.md）
    case bundled
    /// 用户级技能（BaizePath.userSkillsDir/*/SKILL.md，跨所有项目可用）
    case user
    /// 项目级技能（<project>/.baize/skills/*/SKILL.md，仅当前项目可用）
    case project
}

// MARK: - Skill Model

/// 技能数据模型 — 一个 Skill 对应一个 SKILL.md 文件
/// 由 SkillParser 解析 SKILL.md 生成，注册到 SkillRegistry
/// 匹配方式：input.contains(trigger) 命中任一 trigger 即触发
/// 优先级：priority 数值越大优先级越高（按降序排序）
struct Skill: Sendable {
    /// 技能名称（kebab-case，如 "commit-push"）
    let name: String

    /// 技能描述（供 LLM 理解技能用途）
    let description: String

    /// 触发词列表 — 用户输入包含任一触发词即匹配
    /// 例如 ["提交并推送", "commit and push", "/commit-push"]
    let triggers: [String]

    /// 优先级 — 数值越大优先级越高
    /// 多个技能同时匹配时，选 priority 最高的
    let priority: Int

    /// 工作流正文 — Markdown 格式的分步指令
    /// AI 读取后按步骤执行（不做 JS sandbox，纯文本指令）
    let workflow: String

    /// 技能来源 — 标识从哪个目录加载
    let source: SkillSource

    // MARK: - Initialization

    init(
        name: String,
        description: String,
        triggers: [String],
        priority: Int = 0,
        workflow: String,
        source: SkillSource
    ) {
        self.name = name
        self.description = description
        self.triggers = triggers
        self.priority = priority
        self.workflow = workflow
        self.source = source
    }
}
