import Foundation

/// SKILL.md 解析器 — 解析技能文件生成 Skill 实例
///
/// 文件格式（与 BAIZE.md 相同的 YAML frontmatter + Markdown 正文模式）：
/// ```
/// ---
/// name: commit-push
/// description: 提交并推送代码改动
/// triggers:
///   - 提交并推送
///   - commit and push
/// priority: 10
/// ---
/// # 工作流
/// 1. 执行 git add -A
/// 2. 执行 git commit -m "..."
/// 3. 执行 git push
/// ```
///
/// 复用 ProjectContext.parseBaizeMD() 的 YAML frontmatter 解析模式
/// （手动逐行解析 `---` 分隔符，不引入完整 YAML 库）
struct SkillParser {

    // MARK: - Parsing

    /// 解析 SKILL.md 内容生成 Skill
    /// - Parameters:
    ///   - content: SKILL.md 文件全文
    ///   - source: 技能来源（bundled/user/project）
    /// - Returns: 解析后的 Skill，如果格式无效返回 nil
    static func parse(content: String, source: SkillSource) -> Skill? {
        // 1. 分离 YAML 前置元数据和 Markdown 正文
        let (yamlContent, markdownContent) = splitFrontmatter(content: content)

        // 2. 解析 YAML 字段
        let fields = parseSimpleYAML(yamlContent)

        // 3. name 是必需字段
        guard let name = fields["name"]?.first, !name.isEmpty else {
            skillLogger.warning("SkillParser: missing required 'name' field")
            return nil
        }

        let description = fields["description"]?.first ?? ""
        let triggers = fields["triggers"] ?? []
        let priorityString = fields["priority"]?.first ?? "0"
        let priority = Int(priorityString) ?? 0

        // 4. 构建 Skill
        return Skill(
            name: name,
            description: description,
            triggers: triggers,
            priority: priority,
            workflow: markdownContent.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source
        )
    }

    // MARK: - Frontmatter Splitting

    /// 分离 YAML 前置元数据和 Markdown 正文
    /// 复用 ProjectContext.parseBaizeMD() 的 `---` 分隔符解析逻辑
    /// - Parameter content: SKILL.md 文件全文
    /// - Returns: (yaml 文本, markdown 正文)
    private static func splitFrontmatter(content: String) -> (yaml: String, markdown: String) {
        let yamlDelimiter = "---"
        var yamlContent = ""
        var markdownContent = ""
        var inYamlBlock = false
        var yamlBlockCount = 0

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == yamlDelimiter {
                yamlBlockCount += 1
                if yamlBlockCount == 1 {
                    inYamlBlock = true
                    continue
                } else if yamlBlockCount == 2 {
                    inYamlBlock = false
                    continue
                }
            }

            if inYamlBlock {
                yamlContent += line + "\n"
            } else {
                markdownContent += line + "\n"
            }
        }

        return (yamlContent, markdownContent)
    }

    // MARK: - Simple YAML Parser

    /// 简单 YAML 解析器 — 支持 scalar 和 list 类型
    /// 返回 [key: [value]] 格式（list 类型多值，scalar 类型单值数组）
    /// 复用 ProjectContext.parseSimpleYAML() 的手写解析模式
    private static func parseSimpleYAML(_ yaml: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var currentKey: String? = nil

        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }  // 注释行

            // 列表项 (- value)
            if trimmed.hasPrefix("-") {
                let value = trimmed.dropFirst(1).trimmingCharacters(in: .whitespaces)
                // 去除引号
                let cleanedValue = stripQuotes(value)
                if let key = currentKey {
                    result[key, default: []].append(cleanedValue)
                }
                continue
            }

            // 顶层 key: value
            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                let key = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                currentKey = key

                // 行内值（scalar: key: value）
                if parts.count > 1 {
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        let cleanedValue = stripQuotes(value)
                        result[key, default: []].append(cleanedValue)
                    }
                }
            }
        }

        return result
    }

    /// 去除字符串两端的引号（单引号或双引号）
    private static func stripQuotes(_ value: String) -> String {
        var result = value
        if (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
           (result.hasPrefix("'") && result.hasSuffix("'")) {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }
}
