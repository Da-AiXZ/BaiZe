import Foundation
import SwiftUI

/// Git 视图模型 — @MainActor ObservableObject，管理 UI 状态 + 调用 GitService
///
/// 所有 UI 状态在此管理（同 AppState 模式），通过 @Published 绑定 SwiftUI 视图。
/// 所有方法 async，内部调用 GitService actor，捕获错误转 errorMessage。
@MainActor
class GitViewModel: ObservableObject {

    // MARK: - Properties

    /// GitService 引用（actor，跨 actor 边界调用）
    private let gitService: GitService

    // MARK: - Published State

    /// 仓库状态（modified/staged/untracked + 当前分支）
    @Published var status: GitStatus?

    /// 提交历史列表
    @Published var commits: [GitCommit] = []

    /// 分支列表
    @Published var branches: [GitBranch] = []

    /// 当前分支名
    @Published var currentBranch: String = ""

    /// 是否正在加载
    @Published var isLoading: Bool = false

    /// 是否正在推送
    @Published var isPushing: Bool = false

    /// 是否正在提交
    @Published var isCommitting: Bool = false

    /// 是否正在切换分支
    @Published var isSwitchingBranch: Bool = false

    /// 错误消息（用于 Alert）
    @Published var errorMessage: String?

    /// 是否显示错误 Alert
    @Published var showError: Bool = false

    /// 成功提示消息（用于 toast）
    @Published var successMessage: String?

    /// 是否显示成功 toast
    @Published var showSuccess: Bool = false

    /// commit 消息输入
    @Published var commitMessage: String = ""

    /// 当前选中的子 Tab
    @Published var selectedSubTab: GitSubTab = .changes

    /// 当前查看的 diff（用于导航到 GitDiffView）
    @Published var selectedDiff: GitDiffResult?

    /// log 分页偏移（已加载的条数）
    @Published var logSkip: Int = 0

    /// 是否还有更多历史可加载
    @Published var hasMoreCommits: Bool = true

    /// 是否已配置 Git Token
    @Published var hasGitToken: Bool = false

    /// 当前工作目录是否不是 Git 仓库（用于显示初始化空状态）
    @Published var isNotAGitRepository: Bool = false

    /// 是否正在初始化仓库
    @Published var isInitializing: Bool = false

    // MARK: - T02 Published State

    /// 贮藏列表
    @Published var stashList: [GitStashEntry] = []

    /// 标签列表
    @Published var tags: [GitTag] = []

    /// 远程分支列表
    @Published var remoteBranches: [GitBranch] = []

    /// Clone 进度（0-1）
    @Published var cloneProgress: Double = 0

    /// Clone 状态文本
    @Published var cloneStatus: String = ""

    /// 是否正在克隆
    @Published var isCloning: Bool = false

    /// 是否正在 Fetch
    @Published var isFetching: Bool = false

    /// 是否正在 Pull
    @Published var isPulling: Bool = false

    /// 是否正在 Merge
    @Published var isMerging: Bool = false

    /// 是否正在 Rebase
    @Published var isRebasing: Bool = false

    /// 是否正在贮藏操作
    @Published var isStashing: Bool = false

    // MARK: - Initialization

    init(gitService: GitService) {
        self.gitService = gitService
    }

    // MARK: - Status

    /// 刷新仓库状态
    func refreshStatus() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await gitService.status()
            status = result
            currentBranch = result.currentBranch
            hasGitToken = KeychainService().hasGitToken()
            isNotAGitRepository = false
        } catch let gitError as GitError {
            // 非 Git 仓库：不弹 Alert，设置标志位让 UI 显示初始化空状态
            if case .notAGitRepository = gitError {
                isNotAGitRepository = true
                hasGitToken = KeychainService().hasGitToken()
            } else if case .libgit2Error(let code, _) = gitError, code == -9 {
                // GIT_EUNBORNBRANCH: 空仓库（unborn HEAD），不是错误
                // 返回干净状态：工作区干净、分支名 master、无改动、不弹 Alert
                status = GitStatus(modified: [], staged: [], untracked: [], currentBranch: "master")
                currentBranch = "master"
                hasGitToken = KeychainService().hasGitToken()
                isNotAGitRepository = false
            } else {
                showError(gitError.errorDescription ?? "未知错误")
            }
        } catch {
            showError("获取状态失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Init Repository

    /// 在当前工作目录初始化 Git 仓库
    func initRepository() async {
        isInitializing = true
        defer { isInitializing = false }

        do {
            try await gitService.initRepository()
            isNotAGitRepository = false
            showSuccessMessage("Git 仓库已初始化")
            // 初始化后立即刷新状态
            await refreshStatus()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "初始化仓库失败")
        } catch {
            showError("初始化仓库失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Stage

    /// 暂存单个文件
    /// - Parameter path: 文件路径
    func stageFile(_ path: String) async {
        do {
            try await gitService.stage(filePath: path)
            await refreshStatus()
            showSuccessMessage("已暂存: \((path as NSString).lastPathComponent)")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "暂存失败")
        } catch {
            showError("暂存失败: \(error.localizedDescription)")
        }
    }

    /// 暂存所有改动
    func stageAll() async {
        do {
            try await gitService.stageAll()
            await refreshStatus()
            showSuccessMessage("已暂存所有改动")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "暂存失败")
        } catch {
            showError("暂存失败: \(error.localizedDescription)")
        }
    }

    /// 取消暂存单个文件
    /// - Parameter path: 文件路径
    func unstageFile(_ path: String) async {
        do {
            try await gitService.unstage(filePath: path)
            await refreshStatus()
            showSuccessMessage("已取消暂存: \((path as NSString).lastPathComponent)")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "取消暂存失败")
        } catch {
            showError("取消暂存失败: \(error.localizedDescription)")
        }
    }

    /// 取消暂存所有文件
    func unstageAll() async {
        do {
            try await gitService.unstageAll()
            await refreshStatus()
            showSuccessMessage("已取消所有暂存")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "取消暂存失败")
        } catch {
            showError("取消暂存失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Commit

    /// 创建提交
    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            showError("请输入提交消息")
            return
        }

        isCommitting = true
        defer { isCommitting = false }

        do {
            try await gitService.commit(message: message)
            commitMessage = ""
            await refreshStatus()
            await loadLog()
            showSuccessMessage("提交成功")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "提交失败")
        } catch {
            showError("提交失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Push

    /// 推送到远程仓库
    func push() async {
        guard hasGitToken else {
            showError("未配置 GitHub Token，请先在设置中配置")
            return
        }

        isPushing = true
        defer { isPushing = false }

        do {
            try await gitService.push()
            await refreshStatus()
            await loadLog()
            // Bug 4 fix: 推送成功后刷新状态和日志，给用户更明确的反馈
            showSuccessMessage("推送成功！远程仓库已更新")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "推送失败")
        } catch {
            showError("推送失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Log

    /// 加载提交历史（首次加载）
    func loadLog() async {
        logSkip = 0
        hasMoreCommits = true

        do {
            let result = try await gitService.log(limit: BaizeGit.defaultLogLimit, skip: 0)
            commits = result
            logSkip = result.count
            hasMoreCommits = result.count >= BaizeGit.defaultLogLimit
        } catch let gitError as GitError {
            // 空仓库不算错误，静默处理
            if case .emptyRepository = gitError {
                commits = []
                hasMoreCommits = false
            } else if case .libgit2Error(let code, _) = gitError, code < 0 {
                // Bug fix (P0): 任何负错误码（包括 -1 通用错误、-3 GIT_ENOTFOUND、
                // -9 GIT_EUNBORNBRANCH）都视为空仓库无提交历史，不弹 Alert。
                // 之前只 catch 了 -9，遗漏了 -1，导致空仓库切到"历史"Tab 时弹错误 Alert。
                commits = []
                hasMoreCommits = false
            } else {
                showError(gitError.errorDescription ?? "加载历史失败")
            }
        } catch {
            showError("加载历史失败: \(error.localizedDescription)")
        }
    }

    /// 加载更多历史（下拉加载更多）
    func loadMoreLog() async {
        guard hasMoreCommits else { return }

        do {
            let more = try await gitService.log(
                limit: BaizeGit.logPageIncrement,
                skip: logSkip
            )
            commits.append(contentsOf: more)
            logSkip += more.count
            hasMoreCommits = more.count >= BaizeGit.logPageIncrement
        } catch {
            // 静默处理分页加载错误
            hasMoreCommits = false
        }
    }

    // MARK: - Diff

    /// 加载指定文件的 diff
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - diffType: diff 类型
    func loadDiff(filePath: String, diffType: GitDiffType) async {
        do {
            let result = try await gitService.diff(filePath: filePath, diffType: diffType)
            selectedDiff = result
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "加载 diff 失败")
        } catch {
            showError("加载 diff 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Branch (P1)

    /// 加载分支列表
    func loadBranches() async {
        do {
            let result = try await gitService.listBranches()
            branches = result
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "加载分支失败")
        } catch {
            showError("加载分支失败: \(error.localizedDescription)")
        }
    }

    /// 切换分支
    /// - Parameter name: 目标分支名
    func checkoutBranch(_ name: String) async {
        isSwitchingBranch = true
        defer { isSwitchingBranch = false }

        do {
            // 检查工作区是否有未提交改动
            if let currentStatus = status, currentStatus.hasChanges {
                showError("工作区有未提交改动，请先提交或取消暂存后再切换分支")
                return
            }

            try await gitService.checkoutBranch(name)
            await refreshStatus()
            await loadBranches()
            await loadLog()
            showSuccessMessage("已切换到分支: \(name)")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "切换分支失败")
        } catch {
            showError("切换分支失败: \(error.localizedDescription)")
        }
    }

    /// 创建新分支
    /// - Parameter name: 新分支名
    func createBranch(_ name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError("分支名不能为空")
            return
        }

        do {
            try await gitService.createBranch(trimmedName)
            await refreshStatus()
            await loadBranches()
            await loadLog()
            showSuccessMessage("已创建并切换到分支: \(trimmedName)")
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "创建分支失败")
        } catch {
            showError("创建分支失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch (T02)

    /// 从远程仓库拉取更新
    func fetch() async {
        guard hasGitToken else {
            showError("未配置 GitHub Token，请先在设置中配置")
            return
        }

        isFetching = true
        defer { isFetching = false }

        do {
            let result = try await gitService.fetch()
            showSuccessMessage("Fetch 完成（接收 \(result.receivedBytes) 字节）")
            // 刷新远程分支列表
            await loadRemoteBranches()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "Fetch 失败")
        } catch {
            showError("Fetch 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Pull (T02)

    /// 拉取并合并远程更新
    func pull() async {
        guard hasGitToken else {
            showError("未配置 GitHub Token，请先在设置中配置")
            return
        }

        isPulling = true
        defer { isPulling = false }

        do {
            let result = try await gitService.pull()
            if result.success {
                if result.isFastForward {
                    showSuccessMessage("Pull 成功（Fast-forward）")
                } else {
                    showSuccessMessage("Pull 成功（合并完成）")
                }
                await refreshStatus()
                await loadLog()
            } else {
                showError("Pull 遇到冲突，涉及 \(result.conflictFiles.count) 个文件: \(result.conflictFiles.joined(separator: ", "))")
            }
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "Pull 失败")
        } catch {
            showError("Pull 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Merge (T02)

    /// 合并指定分支到当前分支
    func merge(branch: String) async {
        isMerging = true
        defer { isMerging = false }

        do {
            let result = try await gitService.merge(branch: branch)
            if result.success {
                showSuccessMessage(result.isFastForward ? "合并成功（Fast-forward）" : "合并成功")
                await refreshStatus()
                await loadLog()
                await loadBranches()
            } else {
                showError("合并冲突，涉及 \(result.conflictFiles.count) 个文件: \(result.conflictFiles.joined(separator: ", "))")
            }
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "合并失败")
        } catch {
            showError("合并失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Rebase (T02)

    /// 将当前分支变基到指定分支
    func rebase(branch: String) async {
        isRebasing = true
        defer { isRebasing = false }

        do {
            try await gitService.rebase(branch: branch)
            showSuccessMessage("Rebase 成功")
            await refreshStatus()
            await loadLog()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "Rebase 失败")
        } catch {
            showError("Rebase 失败: \(error.localizedDescription)")
        }
    }

    /// 中止 rebase
    func rebaseAbort() async {
        do {
            try await gitService.rebaseAbort()
            showSuccessMessage("Rebase 已中止")
            await refreshStatus()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "中止 Rebase 失败")
        } catch {
            showError("中止 Rebase 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Stash (T02)

    /// 加载贮藏列表
    func loadStashList() async {
        do {
            stashList = try await gitService.stashList()
        } catch let gitError as GitError {
            // 空贮藏列表不算错误
            if case .stashEmpty = gitError {
                stashList = []
            } else {
                showError(gitError.errorDescription ?? "加载贮藏列表失败")
            }
        } catch {
            showError("加载贮藏列表失败: \(error.localizedDescription)")
        }
    }

    /// 贮藏当前改动
    func stashPush(message: String) async {
        isStashing = true
        defer { isStashing = false }

        do {
            try await gitService.stashPush(message: message)
            showSuccessMessage("改动已贮藏")
            await refreshStatus()
            await loadStashList()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "贮藏失败")
        } catch {
            showError("贮藏失败: \(error.localizedDescription)")
        }
    }

    /// 恢复并删除指定贮藏
    func stashPop(index: Int) async {
        isStashing = true
        defer { isStashing = false }

        do {
            try await gitService.stashPop(index: index)
            showSuccessMessage("贮藏已恢复")
            await refreshStatus()
            await loadStashList()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "恢复贮藏失败")
        } catch {
            showError("恢复贮藏失败: \(error.localizedDescription)")
        }
    }

    /// 删除指定贮藏
    func stashDrop(index: Int) async {
        isStashing = true
        defer { isStashing = false }

        do {
            try await gitService.stashDrop(index: index)
            showSuccessMessage("贮藏已删除")
            await loadStashList()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "删除贮藏失败")
        } catch {
            showError("删除贮藏失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Reset (T02)

    /// 重置到指定 commit
    func reset(to oid: String, mode: GitResetMode) async {
        do {
            try await gitService.reset(to: oid, mode: mode)
            showSuccessMessage("已重置（\(mode.displayName)）")
            await refreshStatus()
            await loadLog()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "重置失败")
        } catch {
            showError("重置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Tag (T02)

    /// 加载标签列表
    func loadTags() async {
        do {
            tags = try await gitService.listTags()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "加载标签失败")
        } catch {
            showError("加载标签失败: \(error.localizedDescription)")
        }
    }

    /// 创建标签
    func createTag(name: String, message: String?, targetOid: String?) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError("标签名不能为空")
            return
        }

        do {
            try await gitService.createTag(name: trimmedName, message: message, targetOid: targetOid)
            showSuccessMessage("标签 '\(trimmedName)' 已创建")
            await loadTags()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "创建标签失败")
        } catch {
            showError("创建标签失败: \(error.localizedDescription)")
        }
    }

    /// 删除标签
    func deleteTag(name: String) async {
        do {
            try await gitService.deleteTag(name: name)
            showSuccessMessage("标签 '\(name)' 已删除")
            await loadTags()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "删除标签失败")
        } catch {
            showError("删除标签失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Clone (T02)

    /// 克隆远程仓库
    func clone(remoteURL: String, toPath: String) async {
        isCloning = true
        cloneProgress = 0
        cloneStatus = "准备克隆..."
        defer { isCloning = false }

        do {
            try await gitService.clone(remoteURL: remoteURL, toPath: toPath) { progress, status in
                Task { @MainActor in
                    self.cloneProgress = progress
                    self.cloneStatus = status
                }
            }
            cloneProgress = 1.0
            cloneStatus = "克隆完成"
            showSuccessMessage("仓库克隆成功")
        } catch let gitError as GitError {
            cloneStatus = "克隆失败"
            showError(gitError.errorDescription ?? "克隆失败")
        } catch {
            cloneStatus = "克隆失败"
            showError("克隆失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Branch Delete / Rename (T02)

    /// 删除分支
    func deleteBranch(name: String) async {
        do {
            try await gitService.deleteBranch(name: name)
            showSuccessMessage("分支 '\(name)' 已删除")
            await loadBranches()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "删除分支失败")
        } catch {
            showError("删除分支失败: \(error.localizedDescription)")
        }
    }

    /// 重命名分支
    func renameBranch(oldName: String, newName: String) async {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else {
            showError("新分支名不能为空")
            return
        }

        do {
            try await gitService.renameBranch(oldName: oldName, newName: trimmedNew)
            showSuccessMessage("分支已从 '\(oldName)' 重命名为 '\(trimmedNew)'")
            await loadBranches()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "重命名分支失败")
        } catch {
            showError("重命名分支失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote Branches (T02)

    /// 加载远程分支列表
    func loadRemoteBranches() async {
        do {
            remoteBranches = try await gitService.listRemoteBranches()
        } catch let gitError as GitError {
            // 静默处理远程分支加载失败（可能没有配置远程仓库）
            if case .credentialsMissing = gitError {
                remoteBranches = []
            } else if case .operationFailed = gitError {
                remoteBranches = []
            } else {
                showError(gitError.errorDescription ?? "加载远程分支失败")
            }
        } catch {
            // 静默处理
        }
    }

    /// 检出远程分支
    func checkoutRemoteBranch(name: String) async {
        isSwitchingBranch = true
        defer { isSwitchingBranch = false }

        do {
            try await gitService.checkoutRemoteBranch(name: name)
            showSuccessMessage("已检出远程分支: \(name)")
            await refreshStatus()
            await loadBranches()
            await loadLog()
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "检出远程分支失败")
        } catch {
            showError("检出远程分支失败: \(error.localizedDescription)")
        }
    }

    /// 测试 GitHub Token 连接
    /// - Parameters:
    ///   - token: GitHub Token
    ///   - remoteURL: 远程仓库 URL
    ///   - username: 用户名
    /// - Returns: true 如果连接成功
    func testConnection(token: String, remoteURL: String, username: String) async -> Bool {
        do {
            return try await gitService.testConnection(
                token: token,
                remoteURL: remoteURL,
                username: username
            )
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "连接测试失败")
            return false
        } catch {
            showError("连接测试失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Helpers

    /// 显示错误消息
    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }

    /// 显示成功消息
    private func showSuccessMessage(_ message: String) {
        successMessage = message
        showSuccess = true
        // 2 秒后自动隐藏
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showSuccess = false
        }
    }
}
