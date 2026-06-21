import Foundation

/// 项目上下文 — 读取和解析项目根目录下的 BAIZE.md 配置文件
/// BAIZE.md 类似 CLAUDE.md，定义编码规范、常用命令、安全策略
/// 格式：YAML 前置元数据 + Markdown 正文
/// ---
/// coding_conventions:
///   - "Use TypeScript strict mode"
///   - "Prefer functional components"
/// allowed_commands:
///   - npm
///   - git
///   - node
/// security_policy:
///   deny_paths:
///     - /System
///     - /usr
/// ---
/// 项目描述正文...
/// 修复 C4：改为 class（引用语义），确保 load() 变更在 BaizeApp 中持久化
class ProjectContext {

    // MARK: - Properties

    /// 项目根目录路径
    /// T03: 从 let 改为 var，支持切换项目时更新
    private var rootPath: String

    /// 文件系统服务
    /// T03: 从 let 改为 var，支持切换项目时重建
    private var fileSystemService: FileSystemService

    /// 解析后的 BAIZE.md 配置
    private(set) var config: BaizeConfig?

    /// BAIZE.md 文件是否存在
    private(set) var hasConfigFile: Bool = false

    // MARK: - Initialization

    init(rootPath: String, fileSystemService: FileSystemService? = nil) {
        self.rootPath = rootPath
        // 如果传入了 fileSystemService，使用它；否则创建以 rootPath 为根的新实例
        self.fileSystemService = fileSystemService ?? FileSystemService(rootPath: rootPath)
        self.config = nil
        self.hasConfigFile = false
    }

    // MARK: - Public API

    /// T03: 更新项目根目录 — 切换项目时调用
    /// 更新 rootPath + 重建 fileSystemService + 重新加载 BAIZE.md
    /// - Parameter path: 新的项目根目录绝对路径
    func updateRootPath(_ path: String) async {
        rootPath = path
        // 重建 FileSystemService 以确保内部状态与新根路径一致
        fileSystemService = FileSystemService(rootPath: path)
        agentLogger.info("ProjectContext: rootPath updated to \(path)")
        // 重新加载 BAIZE.md
        do {
            try await load()
        } catch {
            agentLogger.error("ProjectContext: failed to reload BAIZE.md after rootPath update: \(error.localizedDescription)")
        }
    }

    /// 加载项目上下文 — 读取 BAIZE.md 并解析
    /// 修复 C4：class 中无需 mutating 关键字，变更在引用上持久化
    func load() async throws {
        let configPath = (rootPath as NSString).appendingPathComponent(BaizePath.projectConfigFile)

        if fileSystemService.itemExists(at: configPath) {
            hasConfigFile = true
            let content = try fileSystemService.readFile(at: configPath)
            config = parseBaizeMD(content: content)
            agentLogger.info("BAIZE.md loaded: \(configPath) — \(self.config?.codingConventions.count ?? 0) conventions")
        } else {
            hasConfigFile = false
            config = BaizeConfig() // 使用默认配置
            agentLogger.info("No BAIZE.md found, using default config")
        }
    }

    /// 生成系统提示扩展 — 基于 BAIZE.md 配置
    /// AgentLoop 将此扩展拼接在 system prompt 之后
    var systemPromptExtension: String {
        guard let config = config else { return "" }

        var parts: [String] = []

        if !config.codingConventions.isEmpty {
            parts.append("编码规范:")
            for convention in config.codingConventions {
                parts.append("- \(convention)")
            }
        }

        if !config.allowedCommands.isEmpty {
            parts.append("允许的命令:")
            for command in config.allowedCommands {
                parts.append("- \(command)")
            }
        }

        if !config.denyPaths.isEmpty {
            parts.append("禁止访问的路径:")
            for path in config.denyPaths {
                parts.append("- \(path)")
            }
        }

        if !config.projectDescription.isEmpty {
            parts.append("项目描述:\n\(config.projectDescription)")
        }

        return parts.joined(separator: "\n")
    }

    /// 获取允许的命令列表
    var allowedCommands: [String] {
        config?.allowedCommands ?? []
    }

    /// 获取编码规范列表
    var codingConventions: [String] {
        config?.codingConventions ?? []
    }

    /// 获取禁止路径列表
    var denyPaths: [String] {
        config?.denyPaths ?? []
    }

    // MARK: - BAIZE.md Parsing

    /// 解析 BAIZE.md 内容 — YAML 前置元数据 + Markdown 正文
    /// 格式：
    /// ---
    /// key: value
    /// ---
    /// 正文内容
    private func parseBaizeMD(content: String) -> BaizeConfig {
        // 分离 YAML 前置元数据和正文
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

        // 简单 YAML 解析（Phase 1 不引入完整 YAML 库）
        let config = parseSimpleYAML(yamlContent)

        // 将 Markdown 正文作为项目描述
        return BaizeConfig(
            codingConventions: config.codingConventions,
            allowedCommands: config.allowedCommands,
            denyPaths: config.denyPaths,
            projectDescription: markdownContent.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 简单 YAML 解析器（Phase 1 手写，仅支持 list 和 scalar 类型）
    private func parseSimpleYAML(_ yaml: String) -> BaizeConfig {
        var codingConventions: [String] = []
        var allowedCommands: [String] = []
        var denyPaths: [String] = []

        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        var currentKey: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { continue }

            // 顶层 key
            if !trimmed.hasPrefix("-") && trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                currentKey = parts.first?.trimmingCharacters(in: .whitespaces)
                continue
            }

            // 列表项 (- value)
            if trimmed.hasPrefix("-") {
                let value = trimmed.dropFirst(1).trimmingCharacters(in: .whitespaces)
                if let key = currentKey {
                    switch key {
                    case "coding_conventions": codingConventions.append(String(value))
                    case "allowed_commands": allowedCommands.append(String(value))
                    case "deny_paths": denyPaths.append(String(value))
                    default: break
                    }
                }
            }
        }

        return BaizeConfig(
            codingConventions: codingConventions,
            allowedCommands: allowedCommands,
            denyPaths: denyPaths,
            projectDescription: ""
        )
    }
}

// MARK: - BaizeConfig Model

/// BAIZE.md 配置数据模型
struct BaizeConfig: Codable {
    /// 编码规范列表
    var codingConventions: [String]

    /// 允许的 Shell 命令列表
    var allowedCommands: [String]

    /// 禁止访问的文件路径列表
    var denyPaths: [String]

    /// 项目描述（BAIZE.md Markdown 正文）
    var projectDescription: String

    /// 默认配置
    init(
        codingConventions: [String] = [],
        allowedCommands: [String] = ["ls", "cat", "grep", "find", "git", "npm", "node", "python3"],
        denyPaths: [String] = ["/System", "/usr", "/bin", "/sbin"],
        projectDescription: String = ""
    ) {
        self.codingConventions = codingConventions
        self.allowedCommands = allowedCommands
        self.denyPaths = denyPaths
        self.projectDescription = projectDescription
    }
}