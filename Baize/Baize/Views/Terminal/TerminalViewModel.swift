import SwiftUI
import Foundation

/// 终端面板 ViewModel — @MainActor ObservableObject
///
/// 管理命令历史、工作目录、输出行、展开/折叠状态。
/// 用户命令直接调 RuntimeExecutor，不经过 AgentLoop / session.messages，
/// 因此用户手动命令不消耗 LLM Token（双通道独立设计）。
///
/// 生命周期：BaizeApp.init() 创建一次，App 生命周期内不销毁。
/// 命令历史在会话内有效（App 重启清空）。
@MainActor
final class TerminalViewModel: ObservableObject {

    // MARK: - Published State

    /// 输出行数组（LazyVStack 数据源）
    @Published var outputLines: [TerminalLine] = []

    /// 当前工作目录（cd 命令更新此值，其他命令传给 RuntimeExecutor）
    /// T04: didSet 触发重新加载对应项目的命令历史（项目切换时）
    @Published var currentWorkingDir: String = BaizePath.projectRoot {
        didSet {
            // T04: 工作目录变化（通常是项目切换）→ 重新加载该项目的历史命令
            guard oldValue != currentWorkingDir else { return }
            Task { await reloadHistory() }
        }
    }

    /// 命令历史（T04: 跨会话持久化到 TerminalHistoryStore，按项目隔离）
    @Published var commandHistory: [String] = []

    /// 是否正在执行命令
    @Published var isExecuting: Bool = false

    /// 是否展开（Q-T1 定案：默认折叠）
    @Published var isExpanded: Bool = false

    // MARK: - Dependencies

    /// 共享的 RuntimeExecutor 实例（从 AppState 获取，线程安全）
    /// RuntimeExecutor 是 @unchecked Sendable class，内部通过 DispatchQueue 保证线程安全
    private let runtimeExecutor: RuntimeExecutor

    /// T04: 终端历史持久化（actor，按项目隔离，跨会话保留命令历史）
    private let terminalHistoryStore: TerminalHistoryStore?

    // MARK: - Private State

    /// 命令历史导航索引（nil = 未在导航中，输入框显示用户新输入）
    private var historyIndex: Int? = nil

    /// FileManager 用于 cd 路径验证
    private let fileManager = FileManager.default

    /// 取消标志 — cancelExecution() 设置为 true，execute 的 Task 检查此标志
    /// ios_popen 无法真正中断进程，通过标志模拟软中断（忽略输出）
    private var isCancelled: Bool = false

    // MARK: - Init

    /// 初始化 TerminalViewModel
    /// - Parameters:
    ///   - runtimeExecutor: 共享的 RuntimeExecutor 实例
    ///   - initialWorkingDir: 初始工作目录（默认 BaizePath.projectRoot）
    ///   - terminalHistoryStore: T04 终端历史持久化（可选，nil 时退化为会话内不持久化）
    init(
        runtimeExecutor: RuntimeExecutor,
        initialWorkingDir: String = BaizePath.projectRoot,
        terminalHistoryStore: TerminalHistoryStore? = nil
    ) {
        self.runtimeExecutor = runtimeExecutor
        self.currentWorkingDir = initialWorkingDir
        self.terminalHistoryStore = terminalHistoryStore

        // T04: 首次加载该项目的命令历史（跨会话持久化）
        // 注意：currentWorkingDir 的 didSet 在 init 期间不触发（Swift 行为），需手动加载
        if let store = terminalHistoryStore {
            Task { @MainActor in
                let history = await store.load(projectPath: initialWorkingDir)
                self.commandHistory = history
            }
        }
    }

    // MARK: - Command Execution (用户手动)

    /// 执行用户输入的命令
    ///
    /// 特殊命令拦截：cd / clear / pwd 在 ViewModel 层处理，不调 RuntimeExecutor。
    /// 普通命令：显示命令行 → 异步执行 → 显示输出。
    /// 用户命令不进入 session.messages，不消耗 LLM Token。
    ///
    /// - Parameters:
    ///   - command: 原始命令字符串
    ///   - source: 命令来源（默认 .user）
    func execute(command: String, source: CommandSource = .user) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 特殊命令拦截：clear / cls
        if trimmed == "clear" || trimmed == "cls" {
            clear()
            addToHistory(trimmed)
            return
        }

        // 特殊命令拦截：pwd — 直接返回当前工作目录
        if trimmed == "pwd" {
            outputLines.append(TerminalLine(content: currentWorkingDir, type: .output, source: source))
            addToHistory(trimmed)
            autoExpandIfNeeded()
            return
        }

        // 特殊命令拦截：cd — 更新工作目录，不调 RuntimeExecutor
        if trimmed.hasPrefix("cd ") || trimmed == "cd" {
            handleCd(trimmed, source: source)
            addToHistory(trimmed)
            return
        }

        // 普通命令：显示命令行 → 执行 → 显示输出
        outputLines.append(TerminalLine(
            content: "$ \(trimmed)",
            type: .command,
            source: source
        ))
        addToHistory(trimmed)
        autoExpandIfNeeded()

        // 异步执行（不阻塞 UI）
        // RuntimeExecutor.executeCommand 内部通过 DispatchQueue.global 执行 ios_popen，
        // 结果通过 withCheckedContinuation 回主线程
        Task {
            isExecuting = true
            isCancelled = false

            let result = await runtimeExecutor.executeCommand(
                command: trimmed,
                workingDir: currentWorkingDir
            )

            // 检查取消标志 — ios_popen 无法真正中断，但可以忽略输出
            if isCancelled {
                isExecuting = false
                return
            }

            isExecuting = false

            let output = result.formattedOutput
            let lineType: LineType = result.isError ? .error : .output
            outputLines.append(TerminalLine(content: output, type: lineType, source: source))
        }
    }

    // MARK: - Agent Command Interface (由 ChatView 调用)

    /// Agent 命令开始执行时调用（对应 .commandExecuting 事件）
    /// 由 ChatView.handleAgentEvent 在收到 .commandExecuting 时转发
    /// - Parameter command: Agent 执行的命令字符串
    func appendAgentCommand(_ command: String) {
        outputLines.append(TerminalLine(
            content: "$ \(command)",
            type: .command,
            source: .agent
        ))
        autoExpandIfNeeded()
    }

    /// Agent 命令输出到达时调用（对应 .commandOutput 事件）
    /// 由 ChatView.handleAgentEvent 在收到 .commandOutput 时转发
    /// - Parameters:
    ///   - output: 命令输出文本
    ///   - exitCode: 退出码（非 0 标记为错误）
    func appendAgentOutput(_ output: String, exitCode: Int) {
        let lineType: LineType = exitCode != 0 ? .error : .output
        outputLines.append(TerminalLine(content: output, type: lineType, source: .agent))
    }

    // MARK: - cd Handling

    /// 处理 cd 命令 — 更新 currentWorkingDir，不调 RuntimeExecutor
    ///
    /// ios_system 无持久 cd（每条 ios_popen 调用独立），因此 cd 效果
    /// 仅维护在 ViewModel 内存中，其他命令通过 workingDir 参数传递。
    ///
    /// 路径解析规则：
    ///   - cd 无参数 → 回到项目根目录
    ///   - cd .. → 上级目录
    ///   - cd /abs/path → 绝对路径
    ///   - cd rel/path → 基于 currentWorkingDir 拼接
    ///   - 路径不存在 → 错误提示，不更新工作目录
    ///
    /// - Parameters:
    ///   - command: 完整的 cd 命令字符串（如 "cd src"）
    ///   - source: 命令来源
    private func handleCd(_ command: String, source: CommandSource) {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let target: String

        if parts.count <= 1 {
            // cd 无参数 → 回到项目根目录
            target = BaizePath.projectRoot
        } else {
            let rawTarget = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            if rawTarget == ".." {
                // cd .. → 上级目录
                target = (currentWorkingDir as NSString).deletingLastPathComponent
            } else if rawTarget.hasPrefix("/") {
                // 绝对路径
                target = rawTarget
            } else {
                // 相对路径 → 基于 currentWorkingDir 拼接
                target = (currentWorkingDir as NSString)
                    .appendingPathComponent(rawTarget)
            }

            // 路径不存在 → 错误提示，不更新工作目录
            if !fileManager.fileExists(atPath: target) {
                // Bug 3 fix: 改进错误提示，帮助用户理解当前所在位置
                let currentDirName = (currentWorkingDir as NSString).lastPathComponent
                if rawTarget == currentDirName {
                    // 用户试图 cd 进入当前目录的同名子目录（如已在 Baize/ 下执行 cd Baize）
                    outputLines.append(TerminalLine(
                        content: "cd: 已在 '\(currentDirName)' 目录中（当前路径: \(currentWorkingDir)）。\n如需进入子目录，请使用 'ls' 查看可用目录。",
                        type: .error,
                        source: source
                    ))
                } else {
                    outputLines.append(TerminalLine(
                        content: "cd: no such directory: \(rawTarget)\n  (当前路径: \(currentWorkingDir))",
                        type: .error,
                        source: source
                    ))
                }
                return
            }
        }

        currentWorkingDir = target
        outputLines.append(TerminalLine(
            content: "→ \(target)",
            type: .system,
            source: source
        ))
    }

    // MARK: - Utility

    /// 清屏 — 清空输出行数组，保留命令历史
    func clear() {
        outputLines = []
    }

    /// 切换展开/折叠状态
    /// 使用 withAnimation 驱动动画，Bug 5 隔离由 ContentView 的 .transaction 保证
    func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded.toggle()
        }
    }

    /// 命令历史导航 — 上一个命令
    /// 连续调用依次回溯更早的命令
    /// - Returns: 历史命令字符串，无更多历史时返回 nil
    func previousCommand() -> String? {
        guard !commandHistory.isEmpty else { return nil }
        if historyIndex == nil {
            historyIndex = commandHistory.count - 1
        } else if let idx = historyIndex, idx > 0 {
            historyIndex = idx - 1
        }
        return historyIndex.flatMap { commandHistory[$0] }
    }

    /// 命令历史导航 — 下一个命令
    /// 到达最新命令后返回空字符串（清空输入框）
    /// - Returns: 历史命令字符串，或空字符串（退出导航），无历史时返回 nil
    func nextCommand() -> String? {
        guard let idx = historyIndex else { return nil }
        if idx < commandHistory.count - 1 {
            historyIndex = idx + 1
            return commandHistory[historyIndex!]
        } else {
            historyIndex = nil
            return ""  // 清空输入框
        }
    }

    /// 中断当前命令执行（T04）
    /// ios_popen 无法真正中断进程，通过取消标志模拟软中断：
    /// 1. 设置 isCancelled = true
    /// 2. 设置 isExecuting = false（UI 恢复可用）
    /// 3. 追加系统消息提示
    /// 4. ios_popen 完成后 execute 的 Task 检查 isCancelled，跳过输出追加
    func cancelExecution() {
        guard isExecuting else { return }
        isCancelled = true
        isExecuting = false
        outputLines.append(TerminalLine(
            content: "[命令已中断]",
            type: .system,
            source: .user
        ))
    }

    // MARK: - Private Helpers

    /// 添加命令到历史并重置导航索引
    /// T04: 同时异步持久化到 TerminalHistoryStore（按项目隔离，跨会话保留）
    private func addToHistory(_ command: String) {
        commandHistory.append(command)
        historyIndex = nil

        // T04: 异步持久化（TerminalHistoryStore 内部处理连续去重 + 上限 1000 + 排除 clear/cls）
        if let store = terminalHistoryStore {
            let projectPath = currentWorkingDir
            Task { await store.append(command: command, projectPath: projectPath) }
        }
    }

    /// T04: 重新加载当前工作目录对应项目的命令历史
    /// 由 currentWorkingDir didSet 触发（项目切换时）
    private func reloadHistory() async {
        guard let store = terminalHistoryStore else { return }
        let history = await store.load(projectPath: currentWorkingDir)
        commandHistory = history
        historyIndex = nil
    }

    /// P1-6: 命令执行时若终端折叠则自动展开
    /// 使用 withAnimation 驱动，与 Bug 5 隔离策略配合
    private func autoExpandIfNeeded() {
        if !isExpanded {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded = true
            }
        }
    }
}
