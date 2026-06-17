import Foundation

/// 权限引擎 — 实现 allow/ask/deny 三态策略
/// Phase 1 简化策略（非完整 ABAC）：
///   readOnly 工具 → allow（自动允许）
///   destructive 工具 → ask（需要确认）
///   删除关键文件 → deny（直接拒绝）
/// 支持 4 种权限模式切换（default/acceptEdits/plan/bypass）
/// W4 fix: 改为 actor 确保状态共享 + 线程安全
/// 权限模式变更通过 actor isolation 保证即时传播且无数据竞争
actor PermissionEngine {

    // MARK: - Properties

    /// 当前权限模式（actor 隔离保护，线程安全）
    private var mode: PermissionMode

    /// 始终拒绝的操作模式（不可通过权限模式绕过）
    private let alwaysDenyPatterns: Set<String> = BaizePermission.alwaysDenyPatterns

    /// 危险操作关键词
    private let dangerousKeywords: Set<String> = BaizePermission.dangerousKeywords

    // MARK: - Initialization

    init(mode: PermissionMode = BaizePermission.defaultMode) {
        self.mode = mode
    }

    // MARK: - Public API

    /// 设置权限模式（actor 引用语义，变更即时传播，线程安全）
    func setMode(_ newMode: PermissionMode) {
        mode = newMode
        baizeLogger.info("Permission mode changed to: \(newMode.rawValue)")
    }

    /// 获取当前权限模式
    func getMode() -> PermissionMode {
        mode
    }

    /// 评估工具调用的权限决策
    /// - Parameters:
    ///   - toolCall: 待评估的工具调用
    ///   - context: 工具执行上下文
    /// - Returns: PermissionDecision（effect + reason）
    func evaluate(toolCall: ToolCall, context: ToolExecutionContext) -> PermissionDecision {
        let toolName = toolCall.name
        let arguments = toolCall.parsedArguments()

        // Step 1: 终极安全检查 — 某些操作始终拒绝
        if isAlwaysDenied(toolCall: toolCall) {
            return PermissionDecision(
                effect: .deny,
                reason: "此操作涉及系统安全，不可执行"
            )
        }

        // Step 2: 根据权限模式决策
        switch mode {
        case .bypass:
            // 绕过模式：所有操作自动允许（但仍检查终极安全）
            return PermissionDecision(effect: .allow, reason: "绕过模式：自动允许")

        case .plan:
            // 只读规划模式：只允许 readOnly 工具
            let tool = findTool(name: toolName)
            if let tool = tool, tool.isReadOnly {
                return PermissionDecision(effect: .allow, reason: "只读规划：只读操作允许")
            }
            return PermissionDecision(
                effect: .deny,
                reason: "只读规划模式：禁止所有写入和执行操作"
            )

        case .acceptEdits:
            // 接受编辑模式：自动接受文件编辑，执行命令仍需确认
            let tool = findTool(name: toolName)
            if let tool = tool {
                if tool.isReadOnly {
                    return PermissionDecision(effect: .allow, reason: "接受编辑：只读操作自动允许")
                }
                if !tool.isDestructive && isFileEditTool(toolName: toolName) {
                    return PermissionDecision(effect: .allow, reason: "接受编辑：文件编辑自动允许")
                }
                // 执行命令和删除操作仍需确认
                return PermissionDecision(
                    effect: .ask,
                    reason: buildAskReason(toolCall: toolCall)
                )
            }
            return PermissionDecision(effect: .ask, reason: "接受编辑：未知工具需确认")

        case .default:
            // 默认模式：readOnly → allow, destructive → ask, 删除关键 → deny
            let tool = findTool(name: toolName)
            if let tool = tool {
                if tool.isReadOnly {
                    return PermissionDecision(effect: .allow, reason: "只读操作自动允许")
                }
                if tool.isDestructive {
                    // 检查是否删除关键文件
                    if isCriticalFileDeletion(toolCall: toolCall) {
                        return PermissionDecision(
                            effect: .deny,
                            reason: "删除关键文件/目录被拒绝"
                        )
                    }
                    return PermissionDecision(
                        effect: .ask,
                        reason: buildAskReason(toolCall: toolCall)
                    )
                }
                // 非只读、非破坏性 — 需确认
                return PermissionDecision(
                    effect: .ask,
                    reason: buildAskReason(toolCall: toolCall)
                )
            }
            return PermissionDecision(effect: .ask, reason: "未知工具需确认")
        }
    }

    // MARK: - Private Helpers

    /// 终极安全检查：某些操作始终拒绝
    private func isAlwaysDenied(toolCall: ToolCall) -> Bool {
        // 检查命令内容是否包含危险模式
        if toolCall.name == "execute_command" {
            let command = toolCall.argumentString(for: "command") ?? ""
            for pattern in alwaysDenyPatterns {
                if command.contains(pattern) {
                    return true
                }
            }
        }

        // 检查文件删除是否涉及关键系统路径
        if toolCall.name == "write_file" || toolCall.name == "edit_file" {
            let path = toolCall.argumentString(for: "path") ?? ""
            let criticalPaths = ["/System", "/usr", "/bin", "/sbin", "/var/mobile/Library"]
            for criticalPath in criticalPaths {
                if path.hasPrefix(criticalPath) {
                    return true
                }
            }
        }

        return false
    }

    /// 检查是否为关键文件删除操作
    private func isCriticalFileDeletion(toolCall: ToolCall) -> Bool {
        // BAIZE.md 不可删除
        if let path = toolCall.argumentString(for: "path"), path.isBaizeConfig {
            return true
        }

        // 项目根目录不可删除
        if let path = toolCall.argumentString(for: "path"),
           path == BaizePath.projectRoot || path == "/" {
            return true
        }

        return false
    }

    /// 构建需确认操作的人类可读原因描述
    private func buildAskReason(toolCall: ToolCall) -> String {
        let args = toolCall.parsedArguments()

        switch toolCall.name {
        case "write_file":
            let path = args["path"] as? String ?? "未知路径"
            return "将写入/创建文件: \(path)"
        case "edit_file":
            let path = args["path"] as? String ?? "未知路径"
            return "将修改文件: \(path)"
        case "execute_command":
            let command = args["command"] as? String ?? "未知命令"
            return "将执行命令: \(command)"
        case "run_node":
            return "将执行 Node.js 脚本"
        case "run_python":
            return "将执行 Python 脚本"
        default:
            return "将执行操作: \(toolCall.name)"
        }
    }

    /// 判断是否为文件编辑类工具
    private func isFileEditTool(toolName: String) -> Bool {
        ["write_file", "edit_file"].contains(toolName)
    }

    /// 查找工具实例（通过 ToolRegistry 的接口间接获取）
    /// Note: PermissionEngine 不持有 ToolRegistry 引用
    /// 这里使用简化方法判断 isReadOnly/isDestructive
    private func findTool(name: String) -> ToolInfo? {
        // Phase 1: 硬编码工具属性信息（简化实现，避免循环依赖）
        let toolInfos: [String: ToolInfo] = [
            "read_file": ToolInfo(name: "read_file", isReadOnly: true, isDestructive: false),
            "write_file": ToolInfo(name: "write_file", isReadOnly: false, isDestructive: true),
            "edit_file": ToolInfo(name: "edit_file", isReadOnly: false, isDestructive: true),
            "list_directory": ToolInfo(name: "list_directory", isReadOnly: true, isDestructive: false),
            "search_files": ToolInfo(name: "search_files", isReadOnly: true, isDestructive: false),
            "search_content": ToolInfo(name: "search_content", isReadOnly: true, isDestructive: false),
            "execute_command": ToolInfo(name: "execute_command", isReadOnly: false, isDestructive: true),
            "run_node": ToolInfo(name: "run_node", isReadOnly: false, isDestructive: true),
            "run_python": ToolInfo(name: "run_python", isReadOnly: false, isDestructive: true),
        ]
        return toolInfos[name]
    }
}

// MARK: - Permission Decision

/// 权限决策结果
struct PermissionDecision: Sendable {
    let effect: Effect
    let reason: String
}

// MARK: - Tool Info (Simplified)

/// 工具信息摘要（用于权限判断，避免循环依赖）
private struct ToolInfo {
    let name: String
    let isReadOnly: Bool
    let isDestructive: Bool
}