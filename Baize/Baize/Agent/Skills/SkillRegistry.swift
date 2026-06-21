import Foundation

/// 技能注册表 — 管理技能的加载、匹配和执行
///
/// 三级目录扫描（优先级从高到低）：
/// 1. 项目级 — <project>/.baize/skills/*/SKILL.md（项目特定技能，最高优先）
/// 2. 用户级 — BaizePath.userSkillsDir/*/SKILL.md（用户安装技能，跨项目）
/// 3. 内置级 — Bundle.main/skills/*/SKILL.md（App 预装技能）
///
/// 匹配规则：用户输入 contains(trigger)，多技能命中时按 priority 降序取最高
/// 执行方式：返回 workflow 文本给 LLM，AI 按步骤执行（无 JS sandbox）
actor SkillRegistry {

    // MARK: - Properties

    /// 已加载的技能字典 — name → Skill
    private var skills: [String: Skill] = [:]

    // MARK: - Initialization

    init() {
        skillLogger.info("SkillRegistry initialized")
    }

    // MARK: - Loading

    /// 加载内置技能 — 扫描 Bundle.main/skills/*/SKILL.md
    func loadBundledSkills() {
        let bundledDir = BaizePath.bundledSkillsDir
        guard let skillsPath = Bundle.main.resourcePath?
            .appending("/\(bundledDir)") else {
            skillLogger.warning("SkillRegistry: bundled skills directory not found in Bundle")
            return
        }

        let count = loadSkills(from: skillsPath, source: .bundled)
        skillLogger.info("SkillRegistry: loaded \(count) bundled skills from \(skillsPath)")
    }

    /// 加载用户级技能 — 扫描 BaizePath.userSkillsDir/*/SKILL.md
    func loadUserSkills() {
        let count = loadSkills(from: BaizePath.userSkillsDir, source: .user)
        skillLogger.info("SkillRegistry: loaded \(count) user skills from \(BaizePath.userSkillsDir)")
    }

    /// 加载项目级技能 — 扫描 <project>/.baize/skills/*/SKILL.md
    /// - Parameter projectPath: 项目根目录绝对路径
    func loadProjectSkills(path projectPath: String) {
        let projectSkillsDir = (projectPath as NSString)
            .appendingPathComponent(".baize/skills")
        let count = loadSkills(from: projectSkillsDir, source: .project)
        skillLogger.info("SkillRegistry: loaded \(count) project skills from \(projectSkillsDir)")
    }

    /// 从指定目录加载技能 — 扫描子目录中的 SKILL.md
    /// - Parameters:
    ///   - dirPath: 技能根目录路径
    ///   - source: 技能来源标识
    /// - Returns: 成功加载的技能数量
    private func loadSkills(from dirPath: String, source: SkillSource) -> Int {
        let fm = FileManager.default

        guard fm.fileExists(atPath: dirPath) else {
            return 0
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else {
            skillLogger.warning("SkillRegistry: cannot read directory \(dirPath)")
            return 0
        }

        var loadedCount = 0
        for entry in entries {
            let skillDir = (dirPath as NSString).appendingPathComponent(entry)
            let skillMDPath = (skillDir as NSString).appendingPathComponent("SKILL.md")

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let content = try? String(contentsOfFile: skillMDPath, encoding: .utf8) else {
                skillLogger.warning("SkillRegistry: cannot read SKILL.md at \(skillMDPath)")
                continue
            }

            guard let skill = SkillParser.parse(content: content, source: source) else {
                skillLogger.warning("SkillRegistry: failed to parse SKILL.md at \(skillMDPath)")
                continue
            }

            skills[skill.name] = skill
            loadedCount += 1
        }

        return loadedCount
    }

    // MARK: - Matching

    /// 匹配技能 — 根据用户输入查找最匹配的技能
    /// 遍历所有已加载技能的 triggers，input.contains(trigger) 命中即匹配
    /// 多技能命中时按 priority 降序取最高
    /// - Parameter input: 用户输入文本
    /// - Returns: 最匹配的 Skill（如果无匹配返回 nil）
    func matchSkill(input: String) -> Skill? {
        let lowercasedInput = input.lowercased()

        let matched = skills.values.filter { skill in
            skill.triggers.contains { trigger in
                lowercasedInput.contains(trigger.lowercased())
            }
        }

        guard !matched.isEmpty else {
            return nil
        }

        // 按 priority 降序排序，取第一个
        return matched.sorted { $0.priority > $1.priority }.first
    }

    // MARK: - Execution

    /// 执行技能 — 读取 workflow 文本返回给 LLM 按步骤执行
    /// - Parameters:
    ///   - name: 技能名称
    ///   - context: 工具执行上下文
    /// - Returns: ToolResult（成功返回 workflow 文本，失败返回错误）
    func executeSkill(name: String, context: ToolExecutionContext) async -> ToolResult {
        guard let skill = skills[name] else {
            return ToolResult.error(message: "未找到技能: \(name)")
        }

        // 构建技能执行指令文本
        let instruction = """
        ## 技能: \(skill.name)

        \(skill.description)

        ## 工作流

        \(skill.workflow)

        ## 执行说明

        请按照上述工作流步骤逐一执行。每步完成后等待结果，根据结果决定下一步操作。
        """

        return ToolResult.success(
            output: instruction,
            metadata: ["skillName": skill.name, "source": "\(skill.source)"]
        )
    }

    // MARK: - Querying

    /// 获取所有已注册技能列表
    /// - Returns: 所有已加载的 Skill 数组
    func listSkills() -> [Skill] {
        Array(skills.values).sorted { $0.name < $1.name }
    }

    /// 检查技能是否已注册
    /// - Parameter name: 技能名称
    /// - Returns: 是否已注册
    func hasSkill(name: String) -> Bool {
        skills[name] != nil
    }

    /// 获取指定名称的技能
    /// - Parameter name: 技能名称
    /// - Returns: Skill 实例（如果存在）
    func getSkill(name: String) -> Skill? {
        skills[name]
    }
}
