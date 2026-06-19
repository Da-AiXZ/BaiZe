import Foundation

// MARK: - GitCredentialsPayload

/// 凭据载荷 — 传递给 libgit2 credentials 回调的 username + token
/// 使用 class（引用类型）以便通过 Unmanaged 传递 opaque pointer
final class GitCredentialsPayload {
    let username: String
    let token: String

    init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

// MARK: - GitDiffCollector

/// Diff 收集器 — 通过 git_diff_foreach 回调收集 hunk/line 数据
/// 使用 class（引用类型）以便通过 payload 指针在 C 回调中访问
final class GitDiffCollector {
    /// 收集到的 hunk 列表
    var hunks: [GitDiffHunk] = []
    /// 当前正在收集的 hunk 在 hunks 数组中的索引（-1 表示无）
    var currentHunkIndex: Int = -1
    /// 目标文件路径（如果设置，只收集该文件的 diff）
    var targetFilePath: String?
    /// 当前文件是否匹配目标（用于 file_cb 过滤）
    var isCollecting: Bool = true

    /// file_cb 回调 — 文件级别变化
    func onFile(delta: UnsafePointer<git_diff_delta>) {
        // 安全提取文件路径（new_file.path 优先，fallback 到 old_file.path）
        let path: String
        if let newPtr = delta.pointee.new_file.path {
            path = String(cString: newPtr)
        } else if let oldPtr = delta.pointee.old_file.path {
            path = String(cString: oldPtr)
        } else {
            path = ""
        }
        if let target = targetFilePath {
            isCollecting = (path == target)
        } else {
            isCollecting = true
        }
    }

    /// hunk_cb 回调 — Hunk 头部（@@ -oldStart,oldLines +newStart,newLines @@）
    func onHunk(hunk: UnsafePointer<git_diff_hunk>) {
        guard isCollecting else { return }
        let h = hunk.pointee
        let newHunk = GitDiffHunk(
            oldStart: Int(h.old_start),
            oldLines: Int(h.old_lines),
            newStart: Int(h.new_start),
            newLines: Int(h.new_lines),
            lines: []
        )
        hunks.append(newHunk)
        currentHunkIndex = hunks.count - 1
    }

    /// line_cb 回调 — 行级别变化
    func onLine(line: UnsafePointer<git_diff_line>) {
        guard isCollecting else { return }
        guard currentHunkIndex >= 0, currentHunkIndex < hunks.count else { return }

        let l = line.pointee
        let origin = l.origin

        // 确定行类型
        let lineType: GitDiffLineType
        switch origin {
        case Int8(UInt8(ascii: "+")):  // GIT_DIFF_LINE_ADDITION
            lineType = .addition
        case Int8(UInt8(ascii: "-")):  // GIT_DIFF_LINE_DELETION
            lineType = .deletion
        case Int8(UInt8(ascii: " ")):  // GIT_DIFF_LINE_CONTEXT
            lineType = .context
        default:
            // 跳过 header 行 (H, F, B 等)
            return
        }

        // 提取行内容（content 包含前缀字符 +/-/空格，需去掉）
        var contentString = ""
        if let content = l.content {
            let buffer = UnsafeBufferPointer(start: content, count: l.content_len)
            if let fullString = String(bytes: buffer, encoding: .utf8) {
                // 去掉前缀字符（第一个字符是 origin: +/-/空格）
                contentString = String(fullString.dropFirst())
            }
        }

        let diffLine = GitDiffLine(
            type: lineType,
            content: contentString,
            oldLineNumber: l.old_lineno >= 0 ? Int(l.old_lineno) : nil,
            newLineNumber: l.new_lineno >= 0 ? Int(l.new_lineno) : nil
        )

        hunks[currentHunkIndex].lines.append(diffLine)
    }

    /// 构建原始 patch 文本（从收集到的 hunks 拼接）
    func buildRawPatch(filePath: String) -> String {
        var patch = "diff --git a/\(filePath) b/\(filePath)\n"
        for hunk in hunks {
            patch += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\n"
            for line in hunk.lines {
                patch += "\(line.type.prefix)\(line.content)\n"
            }
        }
        return patch
    }
}

// MARK: - GitService

/// Git 核心服务 — actor 封装 libgit2 C API
///
/// libgit2 C API 非线程安全，actor 隔离保证串行访问（同 AgentLoop 模式）。
/// 所有 libgit2 调用在 actor 内执行，外部通过 async 方法调用。
/// 复杂闭包内调 C API 易触发 Swift 类型推断超时 → 提取为独立方法。
///
/// @warning 每次操作都重新打开 repository（不缓存 handle），避免 stale 状态。
/// @note 参考 PythonRuntimeEngine.swift 的 C interop 模式。
actor GitService {

    // MARK: - Properties

    /// 仓库路径（TrollStore: /var/mobile/Documents/Baize/，sandbox fallback: Documents/Baize/）
    private let repositoryPath: String

    /// Keychain 服务（用于读取 Git token）
    private let keychainService: KeychainService

    // MARK: - Initialization

    /// 创建 GitService
    /// - Parameters:
    ///   - repositoryPath: Git 仓库路径
    ///   - keychainService: Keychain 服务实例
    init(repositoryPath: String, keychainService: KeychainService) {
        self.repositoryPath = repositoryPath
        self.keychainService = keychainService
    }

    // MARK: - Error Handling Helpers

    /// 检查 libgit2 返回码，非 0 抛出 GitError
    /// - Parameters:
    ///   - code: libgit2 返回码（0 = 成功，负数 = 错误）
    ///   - operation: 操作描述（用于错误消息）
    private func checkGit(_ code: Int32, operation: String) throws {
        if code < 0 {
            let message: String
            if let errPtr = git_error_last() {
                let msgPtr = errPtr.pointee.message
                message = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            } else {
                message = "Unknown error"
            }
            throw GitError.libgit2Error(code: code, message: "\(operation): \(message)")
        }
    }

    // MARK: - Repository Helpers

    /// 打开 Git 仓库，返回 repository handle
    /// - Returns: OpaquePointer 指向 git_repository
    /// - Throws: GitError 如果仓库不存在或不是 Git 仓库
    private func openRepository() throws -> OpaquePointer {
        var repo: OpaquePointer? = nil
        let code = git_repository_open(&repo, repositoryPath)
        if code != 0 {
            if code == GIT_ENOTFOUND.rawValue {
                throw GitError.notAGitRepository
            }
            try checkGit(code, operation: "git_repository_open")
        }
        guard let handle = repo else {
            throw GitError.notAGitRepository
        }
        return handle
    }

    /// 获取 HEAD 引用对应的 commit
    /// - Parameter repo: 仓库 handle
    /// - Returns: (commit handle, commit OID)
    /// - Throws: GitError 如果仓库为空或读取失败
    private func getHeadCommit(repo: OpaquePointer) throws -> (OpaquePointer, git_oid) {
        var headRef: OpaquePointer? = nil
        let refCode = git_repository_head(&headRef, repo)
        if refCode == GIT_ENOTFOUND.rawValue {
            throw GitError.emptyRepository
        }
        try checkGit(refCode, operation: "git_repository_head")
        defer { git_reference_free(headRef) }

        var headOid = git_oid()
        let peelCode = git_reference_peel(&headOid, headRef, GIT_OBJECT_COMMIT)
        try checkGit(peelCode, operation: "git_reference_peel")

        var commit: OpaquePointer? = nil
        try checkGit(git_commit_lookup(&commit, repo, &headOid), operation: "git_commit_lookup")
        guard let commitHandle = commit else {
            throw GitError.operationFailed("HEAD commit lookup returned nil")
        }
        return (commitHandle, headOid)
    }

    /// 获取 HEAD tree
    /// - Parameter repo: 仓库 handle
    /// - Returns: tree handle（调用者负责 git_tree_free）
    /// - Throws: GitError
    private func getHeadTree(repo: OpaquePointer) throws -> OpaquePointer {
        var headRef: OpaquePointer? = nil
        let refCode = git_repository_head(&headRef, repo)
        if refCode == GIT_ENOTFOUND.rawValue {
            throw GitError.emptyRepository
        }
        try checkGit(refCode, operation: "git_repository_head")
        defer { git_reference_free(headRef) }

        var headOid = git_oid()
        try checkGit(git_reference_peel(&headOid, headRef, GIT_OBJECT_COMMIT), operation: "git_reference_peel")

        var commit: OpaquePointer? = nil
        try checkGit(git_commit_lookup(&commit, repo, &headOid), operation: "git_commit_lookup")
        guard let commitHandle = commit else {
            throw GitError.operationFailed("HEAD commit lookup returned nil")
        }
        defer { git_commit_free(commitHandle) }

        // 从 commit 获取 tree OID，再 lookup tree（返回非 const，可 free）
        let treeOid = git_commit_tree_id(commitHandle)
        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, treeOid), operation: "git_tree_lookup")
        guard let treeHandle = tree else {
            throw GitError.operationFailed("Tree lookup returned nil")
        }
        return treeHandle
    }

    // MARK: - Status

    /// 获取仓库状态 — 返回 modified/staged/untracked 文件列表 + 当前分支
    /// - Returns: GitStatus 结构
    func status() async throws -> GitStatus {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 获取当前分支名
        let branchName = try getCurrentBranchName(repo: repo)

        // 配置 status options
        var opts = git_status_options()
        git_status_init_options(&opts, GIT_STATUS_OPTIONS_VERSION)
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
                          | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
                          | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue)

        var statusList: OpaquePointer? = nil
        try checkGit(git_status_list_new(&statusList, repo, &opts), operation: "git_status_list_new")
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)

        var modified: [GitFileStatus] = []
        var staged: [GitFileStatus] = []
        var untracked: [GitFileStatus] = []

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let statusFlags = entry.pointee.status

            // 分类：先检查 staged (INDEX_*) 再检查 unstaged (WT_*)
            if statusFlags & UInt32(GIT_STATUS_INDEX_NEW.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.head_to_index, isNew: true)
                staged.append(GitFileStatus(path: path, changeStatus: .added, isStaged: true))
            } else if statusFlags & UInt32(GIT_STATUS_INDEX_MODIFIED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.head_to_index, isNew: false)
                staged.append(GitFileStatus(path: path, changeStatus: .modified, isStaged: true))
            } else if statusFlags & UInt32(GIT_STATUS_INDEX_DELETED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.head_to_index, isNew: false)
                staged.append(GitFileStatus(path: path, changeStatus: .deleted, isStaged: true))
            } else if statusFlags & UInt32(GIT_STATUS_INDEX_RENAMED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.head_to_index, isNew: true)
                staged.append(GitFileStatus(path: path, changeStatus: .renamed, isStaged: true))
            }

            if statusFlags & UInt32(GIT_STATUS_WT_NEW.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: true)
                untracked.append(GitFileStatus(path: path, changeStatus: .untracked, isStaged: false))
            } else if statusFlags & UInt32(GIT_STATUS_WT_MODIFIED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: false)
                modified.append(GitFileStatus(path: path, changeStatus: .modified, isStaged: false))
            } else if statusFlags & UInt32(GIT_STATUS_WT_DELETED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: false)
                modified.append(GitFileStatus(path: path, changeStatus: .deleted, isStaged: false))
            } else if statusFlags & UInt32(GIT_STATUS_WT_RENAMED.rawValue) != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: true)
                modified.append(GitFileStatus(path: path, changeStatus: .renamed, isStaged: false))
            }
        }

        return GitStatus(
            modified: modified,
            staged: staged,
            untracked: untracked,
            currentBranch: branchName
        )
    }

    /// 从 git_diff_delta 提取文件路径
    private func extractPath(from delta: UnsafeMutablePointer<git_diff_delta>?, isNew: Bool) -> String {
        guard let delta = delta else { return "(unknown)" }
        let pathPtr = isNew ? delta.pointee.new_file.path : delta.pointee.old_file.path
        if let path = pathPtr {
            return String(cString: path)
        }
        return "(unknown)"
    }

    /// 获取当前分支名（从 repository handle）
    private func getCurrentBranchName(repo: OpaquePointer) throws -> String {
        var headRef: OpaquePointer? = nil
        let code = git_repository_head(&headRef, repo)
        if code == GIT_ENOTFOUND.rawValue {
            return "HEAD (detached)"
        }
        try checkGit(code, operation: "git_repository_head")
        defer { git_reference_free(headRef) }

        var buf = git_buf(ptr: nil, size: 0, asize: 0)
        let branchCode = git_branch_name(&buf, headRef)
        if branchCode == 0, let ptr = buf.ptr {
            let name = String(cString: ptr)
            git_buf_dispose(&buf)
            return name
        }
        git_buf_dispose(&buf)
        return "HEAD"
    }

    // MARK: - Diff

    /// 获取指定文件的 diff
    /// - Parameters:
    ///   - filePath: 文件路径（相对仓库根目录）
    ///   - diffType: diff 类型（工作区 vs 暂存区 / 暂存区 vs HEAD）
    /// - Returns: GitDiffResult 结构
    func diff(filePath: String, diffType: GitDiffType) async throws -> GitDiffResult {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var diff: OpaquePointer? = nil
        var diffOpts = git_diff_options()
        git_diff_init_options(&diffOpts, GIT_DIFF_OPTIONS_VERSION)

        switch diffType {
        case .workingTreeVsIndex:
            // 工作区 vs 暂存区（未暂存的改动）
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            try checkGit(
                git_diff_index_to_workdir(&diff, repo, index, &diffOpts),
                operation: "git_diff_index_to_workdir"
            )

        case .indexVsHead:
            // 暂存区 vs HEAD（已暂存的改动）
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            try checkGit(
                git_diff_tree_to_index(&diff, repo, headTree, index, &diffOpts),
                operation: "git_diff_tree_to_index"
            )
        }

        defer { git_diff_free(diff) }

        // 使用 GitDiffCollector 收集 diff 数据
        let collector = GitDiffCollector()
        collector.targetFilePath = filePath
        let payload = Unmanaged.passUnretained(collector).toOpaque()

        // 定义非捕获 C 回调闭包
        let fileCb: git_diff_file_cb = { delta, _, payload in
            guard let payload = payload, let delta = delta else { return 0 }
            let collector = Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue()
            collector.onFile(delta: delta)
            return 0
        }

        let hunkCb: git_diff_hunk_cb = { _, hunk, payload in
            guard let payload = payload, let hunk = hunk else { return 0 }
            let collector = Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue()
            collector.onHunk(hunk: hunk)
            return 0
        }

        let lineCb: git_diff_line_cb = { _, _, line, payload in
            guard let payload = payload, let line = line else { return 0 }
            let collector = Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue()
            collector.onLine(line: line)
            return 0
        }

        // 执行 diff 遍历
        let forEachCode = git_diff_foreach(diff, fileCb, nil, hunkCb, lineCb, payload)
        try checkGit(forEachCode, operation: "git_diff_foreach")

        let rawPatch = collector.buildRawPatch(filePath: filePath)

        return GitDiffResult(
            filePath: filePath,
            diffType: diffType,
            hunks: collector.hunks,
            rawPatch: rawPatch
        )
    }

    // MARK: - Stage

    /// 暂存单个文件
    /// - Parameter filePath: 文件路径（相对仓库根目录）
    func stage(filePath: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }

        let code = filePath.withCString { pathPtr in
            git_index_add_bypath(index, pathPtr)
        }

        if code != 0 {
            throw GitError.stageFailed("git_index_add_bypath failed for '\(filePath)' (code: \(code))")
        }
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    /// 暂存所有改动（包括未追踪文件）
    func stageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }

        // git_index_add_all with NULL pathspec = add everything
        var pathspec = git_strarray(strings: nil, count: 0)
        let code = git_index_add_all(index, &pathspec, 0, nil, nil)
        if code != 0 {
            throw GitError.stageFailed("git_index_add_all failed (code: \(code))")
        }
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    // MARK: - Unstage

    /// 取消暂存单个文件（从 HEAD 恢复 index 条目）
    /// - Parameter filePath: 文件路径（相对仓库根目录）
    func unstage(filePath: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 使用 git_reset_default 从 HEAD 恢复 index 条目
        // 需要 HEAD commit 的 tree 和目标路径
        do {
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }

            // 使用 withCString 安全地构造 pathspec
            try filePath.withCString { pathPtr in
                var pathStrings: [UnsafePointer<CChar>?] = [UnsafePointer(pathPtr)]
                var pathspec = git_strarray(strings: &pathStrings, count: 1)

                let code = git_reset_default(repo, headTree, &pathspec)
                if code != 0 {
                    // 如果 git_reset_default 失败，尝试 git_index_remove
                    var index: OpaquePointer? = nil
                    _ = git_repository_index(&index, repo)
                    if let idx = index {
                        let removeCode = git_index_remove_bypath(idx, pathPtr)
                        if removeCode == 0 {
                            _ = git_index_write(idx)
                        }
                        git_index_free(idx)
                        if removeCode != 0 {
                            throw GitError.stageFailed("unstage failed for '\(filePath)' (reset code: \(code), remove code: \(removeCode))")
                        }
                    } else {
                        throw GitError.stageFailed("unstage failed for '\(filePath)' (reset code: \(code))")
                    }
                }
            }
        } catch GitError.emptyRepository {
            // 空仓库（无 HEAD），直接从 index 删除
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }

            let removeCode = filePath.withCString { pathPtr in
                git_index_remove_bypath(index, pathPtr)
            }
            if removeCode != 0 {
                throw GitError.stageFailed("unstage failed for '\(filePath)' in empty repo (code: \(removeCode))")
            }
            try checkGit(git_index_write(index), operation: "git_index_write")
        }
    }

    /// 取消暂存所有文件
    func unstageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        do {
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }

            // NULL pathspec = reset all
            var pathspec = git_strarray(strings: nil, count: 0)
            let code = git_reset_default(repo, headTree, &pathspec)
            if code != 0 {
                throw GitError.stageFailed("unstageAll failed (code: \(code))")
            }
        } catch GitError.emptyRepository {
            // 空仓库：清空 index
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            var pathspec = git_strarray(strings: nil, count: 0)
            _ = git_index_remove_all(index, &pathspec, nil, nil)
            try checkGit(git_index_write(index), operation: "git_index_write")
        }
    }

    // MARK: - Commit

    /// 创建提交
    /// - Parameter message: 提交消息
    func commit(message: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 创建签名
        var sig: OpaquePointer? = nil
        let authorName = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? BaizeGit.defaultCommitAuthor
        let authorEmail = BaizeGit.defaultCommitEmail
        let sigCode = authorName.withCString { namePtr in
            authorEmail.withCString { emailPtr in
                git_signature_now(&sig, namePtr, emailPtr)
            }
        }
        try checkGit(sigCode, operation: "git_signature_now")
        defer { git_signature_free(sig) }
        guard let signature = sig else {
            throw GitError.commitFailed("Signature creation returned nil")
        }

        // 获取 index 并写入 tree
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }

        var treeOid = git_oid()
        try checkGit(git_index_write_tree(&treeOid, index), operation: "git_index_write_tree")

        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, &treeOid), operation: "git_tree_lookup")
        defer { git_tree_free(tree) }

        // 获取 HEAD commit 作为 parent（如果是首次提交则无 parent）
        do {
            let (parentCommit, _) = try getHeadCommit(repo: repo)
            defer { git_commit_free(parentCommit) }

            // 创建带 parent 的提交
            var commitOid = git_oid()
            var parents: [OpaquePointer?] = [parentCommit]
            let createCode = message.withCString { msgPtr in
                git_commit_create(
                    &commitOid,
                    repo,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    msgPtr,
                    tree,
                    1,
                    &parents
                )
            }
            try checkGit(createCode, operation: "git_commit_create")

        } catch GitError.emptyRepository {
            // 首次提交（无 HEAD），创建无 parent 的提交
            var commitOid = git_oid()
            let createCode = message.withCString { msgPtr in
                git_commit_create(
                    &commitOid,
                    repo,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    msgPtr,
                    tree,
                    0,
                    nil
                )
            }
            try checkGit(createCode, operation: "git_commit_create (initial)")
        }
    }

    // MARK: - Push

    /// 推送到远程仓库
    /// 从 KeychainService 读取 token，通过 credentials 回调注入
    func push() async throws {
        // 读取凭据
        guard let token = keychainService.loadGitToken(), !token.isEmpty else {
            throw GitError.credentialsMissing
        }
        let username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? "git"

        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 获取当前分支名
        let branchName = try getCurrentBranchName(repo: repo)

        // 查找远程
        var remote: OpaquePointer? = nil
        try checkGit(git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName), operation: "git_remote_lookup")
        defer { git_remote_free(remote) }

        // 构造 push options with credentials callback
        var pushOpts = git_push_options()
        git_push_init_options(&pushOpts, GIT_PUSH_OPTIONS_VERSION)

        // 设置 credentials callback
        let payload = GitCredentialsPayload(username: username, token: token)
        let payloadPointer = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<GitCredentialsPayload>.fromOpaque(payloadPointer).release() }

        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, GIT_REMOTE_CALLBACKS_VERSION)
        callbacks.credentials = credentialsCallback
        callbacks.payload = payloadPointer
        pushOpts.callbacks = callbacks

        // 构造 refspec: refs/heads/{branch}:refs/heads/{branch}
        let refspec = "refs/heads/\(branchName):refs/heads/\(branchName)"
        var refs = git_strarray(strings: nil, count: 0)

        let pushCode = refspec.withCString { refspecPtr in
            var refspecPtrs: [UnsafePointer<CChar>?] = [UnsafePointer(refspecPtr)]
            refs = git_strarray(strings: &refspecPtrs, count: 1)
            return git_remote_push(remote, &refs, &pushOpts)
        }
        if pushCode != 0 {
            let errMsg: String
            if let errPtr = git_error_last() {
                let msgPtr = errPtr.pointee.message
                errMsg = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            } else {
                errMsg = "Unknown error"
            }
            throw GitError.pushFailed(errMsg)
        }
    }

    /// libgit2 credentials 回调 — 非捕获 C 函数指针
    /// 通过 payload 获取 GitCredentialsPayload，创建 userpass plaintext credential
    private let credentialsCallback: git_credential_acquire_cb = { out, _, _, _, payload in
        guard let payload = payload else { return -1 }
        let creds = Unmanaged<GitCredentialsPayload>.fromOpaque(payload).takeUnretainedValue()
        let code = creds.username.withCString { usernamePtr in
            creds.token.withCString { tokenPtr in
                git_credential_userpass_plaintext_new(out, usernamePtr, tokenPtr)
            }
        }
        return code
    }

    // MARK: - Log

    /// 获取提交历史
    /// - Parameters:
    ///   - limit: 最大返回条数
    ///   - skip: 跳过前 N 条（用于分页）
    /// - Returns: GitCommit 数组
    func log(limit: Int = BaizeGit.defaultLogLimit, skip: Int = 0) async throws -> [GitCommit] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var walker: OpaquePointer? = nil
        try checkGit(git_revwalk_new(&walker, repo), operation: "git_revwalk_new")
        defer { git_revwalk_free(walker) }

        try checkGit(git_revwalk_push_head(walker), operation: "git_revwalk_push_head")
        git_revwalk_sorting(walker, UInt32(GIT_SORT_TIME.rawValue))

        var commits: [GitCommit] = []
        var skipped = 0
        var oid = git_oid()

        while git_revwalk_next(&oid, walker) == 0 {
            if skipped < skip {
                skipped += 1
                continue
            }
            if commits.count >= limit {
                break
            }

            var commit: OpaquePointer? = nil
            let lookupCode = git_commit_lookup(&commit, repo, &oid)
            if lookupCode != 0 {
                continue
            }
            defer { git_commit_free(commit) }
            guard let commitHandle = commit else { continue }

            let author = git_commit_author(commitHandle)
            let authorName = author.map { String(cString: $0.pointee.name) } ?? "Unknown"
            let authorEmail = author.map { String(cString: $0.pointee.email) } ?? ""
            let commitTime = author.map { $0.pointee.when.time } ?? 0
            let date = Date(timeIntervalSince1970: TimeInterval(commitTime))

            let messagePtr = git_commit_message(commitHandle)
            let message = messagePtr.map { String(cString: $0) } ?? ""

            // 获取 OID 字符串
            let oidPtr = withUnsafePointer(to: &oid) { ptr -> String in
                guard let hexPtr = git_oid_tostr_s(ptr) else { return "" }
                return String(cString: hexPtr)
            }

            commits.append(GitCommit(
                oid: oidPtr,
                author: authorName,
                email: authorEmail,
                date: date,
                message: message
            ))
        }

        return commits
    }

    // MARK: - Current Branch

    /// 获取当前分支名
    func currentBranch() async throws -> String {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        return try getCurrentBranchName(repo: repo)
    }

    // MARK: - Test Connection

    /// 测试 GitHub Token 连接（不走 libgit2，直接用 URLSession 调 GitHub API）
    /// - Parameters:
    ///   - token: GitHub Personal Access Token
    ///   - remoteURL: 远程仓库 URL（P0 仅用于显示，不参与验证）
    ///   - username: 用户名（P0 仅用于显示，不参与验证）
    /// - Returns: true 如果连接成功
    func testConnection(token: String, remoteURL: String, username: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: BaizeGit.githubUserAPI)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitError.networkError("Invalid response")
            }
            if httpResponse.statusCode == 200 {
                return true
            } else if httpResponse.statusCode == 401 {
                throw GitError.credentialsInvalid
            } else {
                throw GitError.networkError("GitHub API returned status \(httpResponse.statusCode)")
            }
        } catch let urlError as URLError {
            throw GitError.networkError(urlError.localizedDescription)
        } catch let gitError as GitError {
            throw gitError
        } catch {
            throw GitError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Branch (P1)

    /// 列出所有本地分支
    /// - Returns: GitBranch 数组
    func listBranches() async throws -> [GitBranch] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        let currentBranchName = try getCurrentBranchName(repo: repo)

        var branches: [GitBranch] = []
        var iter: OpaquePointer? = nil
        try checkGit(
            git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL),
            operation: "git_branch_iterator_new"
        )
        defer { git_branch_iterator_free(iter) }

        var ref: OpaquePointer? = nil
        var branchType = git_branch_t(GIT_BRANCH_LOCAL.rawValue)

        while git_branch_next(&ref, &branchType, iter) == 0 {
            defer { git_reference_free(ref) }

            var buf = git_buf(ptr: nil, size: 0, asize: 0)
            if git_branch_name(&buf, ref) == 0, let ptr = buf.ptr {
                let name = String(cString: ptr)
                branches.append(GitBranch(
                    name: name,
                    isCurrent: name == currentBranchName,
                    isRemote: false
                ))
            }
            git_buf_dispose(&buf)
        }

        return branches
    }

    /// 切换分支
    /// - Parameter name: 目标分支名
    func checkoutBranch(_ name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 查找目标分支引用
        var branchRef: OpaquePointer? = nil
        try checkGit(
            git_branch_lookup(&branchRef, repo, name, GIT_BRANCH_LOCAL),
            operation: "git_branch_lookup(\(name))"
        )
        defer { git_reference_free(branchRef) }

        // 获取分支指向的 commit
        var targetOid = git_oid()
        try checkGit(
            git_reference_peel(&targetOid, branchRef, GIT_OBJECT_COMMIT),
            operation: "git_reference_peel"
        )

        var targetCommit: OpaquePointer? = nil
        try checkGit(git_commit_lookup(&targetCommit, repo, &targetOid), operation: "git_commit_lookup")
        defer { git_commit_free(targetCommit) }

        // Checkout target commit tree
        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, GIT_CHECKOUT_OPTIONS_VERSION)
        checkoutOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

        let tree = git_commit_tree(targetCommit)
        try checkGit(git_checkout_tree(repo, tree, &checkoutOpts), operation: "git_checkout_tree")

        // 设置 HEAD 指向目标分支
        let refspec = "refs/heads/\(name)"
        try checkGit(
            git_repository_set_head(repo, refspec),
            operation: "git_repository_set_head"
        )
    }

    /// 创建新分支并自动 checkout
    /// - Parameter name: 新分支名
    func createBranch(_ name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 获取 HEAD commit
        let (headCommit, headOid) = try getHeadCommit(repo: repo)
        defer { git_commit_free(headCommit) }

        // 创建分支
        var newBranch: OpaquePointer? = nil
        let createCode = name.withCString { namePtr in
            git_branch_create(&newBranch, repo, namePtr, headCommit, 0)
        }
        try checkGit(createCode, operation: "git_branch_create")
        git_reference_free(newBranch)

        // Checkout 新分支
        try await checkoutBranch(name)
    }
}
