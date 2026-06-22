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

    /// R1 扩展：ToolRegistry 引用 — 用于动态查询工具属性（替代硬编码 ToolInfo 列表）
    /// 在 BaizeApp.init() 中通过 setToolRegistry() 注入
    /// 无循环引用：ToolRegistry 不持有 PermissionEngine 引用
    private var toolRegistry: ToolRegistry?

    /// B07 fix: 会话级授权集合 — "本次会话不再询问"存储的工具+操作 key
    /// key 格式: "toolName" 或 "toolName:operation"
    /// 用户在权限对话框勾选"本次会话不再询问"时添加，会话结束时清除
    private var sessionApprovals: Set<String> = []

    // MARK: - Initialization

    init(mode: PermissionMode = BaizePermission.defaultMode) {
        self.mode = mode
    }

    // MARK: - R1 扩展：ToolRegistry 注入

    /// 注入 ToolRegistry 引用 — 用于动态查询工具属性和调用 needsPermission()
    /// 在 BaizeApp.init() 中 PermissionEngine 和 ToolRegistry 都创建后调用
    func setToolRegistry(_ registry: ToolRegistry) {
        toolRegistry = registry
        baizeLogger.info("PermissionEngine: ToolRegistry injected for dynamic tool lookup")
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

    // MARK: - B07 fix: Session Approval API

    /// 添加会话级授权（"本次会话不再询问"时调用）
    /// - Parameters:
    ///   - toolName: 工具名称
    ///   - operation: 操作描述（可选，如 "write_file:/path/to/file"）
    func grantSessionApproval(forTool toolName: String, operation: String? = nil) {
        let key = sessionApprovalKey(toolName: toolName, operation: operation)
        sessionApprovals.insert(key)
        let totalCount = sessionApprovals.count
        baizeLogger.info("Session approval granted for: \(key) (total: \(totalCount))")
    }

    /// 检查是否有会话级授权
    func hasSessionApproval(forTool toolName: String, operation: String? = nil) -> Bool {
        let key = sessionApprovalKey(toolName: toolName, operation: operation)
        if sessionApprovals.contains(key) { return true }
        // 也检查只有 toolName 的通配授权
        return sessionApprovals.contains(toolName)
    }

    /// 清除所有会话级授权
    func clearSessionApprovals() {
        let count = sessionApprovals.count
        sessionApprovals.removeAll()
        if count > 0 {
            baizeLogger.info("Cleared \(count) session approvals")
        }
    }

    /// 构建会话授权 key
    private func sessionApprovalKey(toolName: String, operation: String?) -> String {
        if let op = operation, !op.isEmpty {
            return "\(toolName):\(op)"
        }
        return toolName
    }

    /// 评估工具调用的权限决策
    /// R1 扩展：改为 async 以支持调用 ToolRegistry 动态查询 + tool.needsPermission() 运行时判断
    /// 不破坏现有 .allow/.ask/.deny 逻辑：在现有逻辑基础上新增 needsPermission 调用
    /// - Parameters:
    ///   - toolCall: 待评估的工具调用
    ///   - context: 工具执行上下文
    /// - Returns: PermissionDecision（effect + reason）
    func evaluate(toolCall: ToolCall, context: ToolExecutionContext) async -> PermissionDecision {
        let toolName = toolCall.name
        let arguments = toolCall.parsedArguments()

        // Step 1: 终极安全检查 — 某些操作始终拒绝
        if isAlwaysDenied(toolCall: toolCall) {
            return PermissionDecision(
                effect: .deny,
                reason: "此操作涉及系统安全，不可执行"
            )
        }

        // Step 2: 根据权限模式决策（现有逻辑不变）
        let decision: PermissionDecision
        switch mode {
        case .bypass:
            // 绕过模式：所有操作自动允许（但仍检查终极安全）
            decision = PermissionDecision(effect: .allow, reason: "绕过模式：自动允许")

        case .plan:
            // 只读规划模式：只允许 readOnly 工具
            let toolInfo = await findTool(name: toolName)
            if let toolInfo = toolInfo, toolInfo.isReadOnly {
                decision = PermissionDecision(effect: .allow, reason: "只读规划：只读操作允许")
            } else {
                decision = PermissionDecision(
                    effect: .deny,
                    reason: "只读规划模式：禁止所有写入和执行操作"
                )
            }

        case .acceptEdits:
            // 接受编辑模式：自动接受文件编辑，执行命令仍需确认
            let toolInfo = await findTool(name: toolName)
            if let toolInfo = toolInfo {
                if toolInfo.isReadOnly {
                    decision = PermissionDecision(effect: .allow, reason: "接受编辑：只读操作自动允许")
                } else if !toolInfo.isDestructive && isFileEditTool(toolName: toolName) {
                    decision = PermissionDecision(effect: .allow, reason: "接受编辑：文件编辑自动允许")
                } else {
                    // 执行命令和删除操作仍需确认
                    decision = PermissionDecision(
                        effect: .ask,
                        reason: buildAskReason(toolCall: toolCall)
                    )
                }
            } else {
                decision = PermissionDecision(effect: .ask, reason: "接受编辑：未知工具需确认")
            }

        case .default:
            // 默认模式：readOnly → allow, destructive → ask, 删除关键 → deny
            let toolInfo = await findTool(name: toolName)
            if let toolInfo = toolInfo {
                if toolInfo.isReadOnly {
                    decision = PermissionDecision(effect: .allow, reason: "只读操作自动允许")
                } else if toolInfo.isDestructive {
                    // 检查是否删除关键文件
                    if isCriticalFileDeletion(toolCall: toolCall) {
                        decision = PermissionDecision(
                            effect: .deny,
                            reason: "删除关键文件/目录被拒绝"
                        )
                    } else {
                        decision = PermissionDecision(
                            effect: .ask,
                            reason: buildAskReason(toolCall: toolCall)
                        )
                    }
                } else {
                    // 非只读、非破坏性 — 需确认
                    decision = PermissionDecision(
                        effect: .ask,
                        reason: buildAskReason(toolCall: toolCall)
                    )
                }
            } else {
                decision = PermissionDecision(effect: .ask, reason: "未知工具需确认")
            }
        }

        // B07 fix: 检查会话级授权 — "本次会话不再询问"的工具直接放行
        // 在 needsPermission 检查之前，将 .ask 转为 .allow
        if decision.effect == .ask {
            let operationKey = buildOperationKey(toolCall: toolCall)
            if hasSessionApproval(forTool: toolName, operation: operationKey) {
                return PermissionDecision(effect: .allow, reason: "会话级授权：本次会话不再询问")
            }
        }

        // Step 3: R1 新增 — 运行时 needsPermission() 检查
        // 在现有决策基础上，调用工具自身的 needsPermission() 做运行时权限判断
        // 只有当现有决策为 .allow 时才检查（.ask 和 .deny 已经足够严格）
        // B06 fix: bypass 模式跳过 needsPermission 检查，确保 bypass 真正绕过所有权限
        if decision.effect == .allow, mode != .bypass, let registry = toolRegistry {
            let tool = await registry.getTool(name: toolName)
            let toolPermission = tool?.needsPermission(input: arguments, context: context)

            switch toolPermission {
            case .deny(let reason):
                // 工具自身拒绝 — 覆盖为 ask（不直接 deny，给用户确认机会）
                return PermissionDecision(effect: .ask, reason: reason)
            case .ask(let reason):
                // 工具自身要求确认 — 覆盖为 ask
                return PermissionDecision(effect: .ask, reason: reason)
            case .allow, .none:
                // 工具自身允许或无工具实现 — 保持现有决策
                return decision
            }
        }

        return decision
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

        // 检查文件操作是否涉及关键系统路径（写入/编辑/删除）
        if toolCall.name == "write_file" || toolCall.name == "edit_file" || toolCall.name == "delete_file" {
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
        case "delete_file":
            let path = args["path"] as? String ?? "未知路径"
            return "将删除文件/目录: \(path)"
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

    /// B07 fix: 构建操作级 key — 用于会话级授权的精细匹配
    /// 不同操作有不同的 key，如 write_file 的 key 包含文件路径
    private func buildOperationKey(toolCall: ToolCall) -> String {
        let args = toolCall.parsedArguments()
        switch toolCall.name {
        case "write_file", "edit_file", "delete_file":
            let path = args["path"] as? String ?? ""
            return path
        case "execute_command":
            let command = args["command"] as? String ?? ""
            // 取命令的第一个词作为 key（如 "rm" 而非 "rm -rf /tmp"）
            return command.split(separator: " ").first.map(String.init) ?? command
        case "run_node", "run_python":
            return "" // 进程工具不区分操作
        default:
            return ""
        }
    }

    /// 查找工具信息（R1 扩展：优先使用 ToolRegistry 动态查询，回退到硬编码列表）
    /// - Parameter name: 工具名称
    /// - Returns: ToolInfo（工具名、是否只读、是否危险）
    /// R1 变更：优先从 ToolRegistry 查询 Tool 实例，获取 isReadOnly/isDestructive 属性
    /// 如果 ToolRegistry 不可用（nil）或工具未注册，回退到硬编码 ToolInfo 列表
    /// 这保证了现有 10 个工具在 ToolRegistry 注入前后都能正常工作
    private func findTool(name: String) async -> ToolInfo? {
        // 优先：从 ToolRegistry 动态查询
        if let registry = toolRegistry {
            let tool = await registry.getTool(name: name)
            if let tool = tool {
                return ToolInfo(
                    name: tool.name,
                    isReadOnly: tool.isReadOnly,
                    isDestructive: tool.isDestructive
                )
            }
        }

        // 回退：硬编码工具属性信息（确保 ToolRegistry 未注入时仍可工作）
        let toolInfos: [String: ToolInfo] = [
            "read_file": ToolInfo(name: "read_file", isReadOnly: true, isDestructive: false),
            "write_file": ToolInfo(name: "write_file", isReadOnly: false, isDestructive: true),
            "edit_file": ToolInfo(name: "edit_file", isReadOnly: false, isDestructive: true),
            "list_directory": ToolInfo(name: "list_directory", isReadOnly: true, isDestructive: false),
            "search_files": ToolInfo(name: "search_files", isReadOnly: true, isDestructive: false),
            "search_content": ToolInfo(name: "search_content", isReadOnly: true, isDestructive: false),
            "delete_file": ToolInfo(name: "delete_file", isReadOnly: false, isDestructive: true),
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