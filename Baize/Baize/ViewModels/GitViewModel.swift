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
        } catch let gitError as GitError {
            showError(gitError.errorDescription ?? "未知错误")
        } catch {
            showError("获取状态失败: \(error.localizedDescription)")
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
            showSuccessMessage("推送成功")
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

    // MARK: - Test Connection

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
