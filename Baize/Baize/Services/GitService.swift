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
    var hunks: [GitDiffHunk] = []
    var currentHunkIndex: Int = -1
    var targetFilePath: String?
    var isCollecting: Bool = true

    func onFile(delta: UnsafePointer<git_diff_delta>) {
        let path: String
        if let newPtr = delta.pointee.new_file.path {
            path = String(cString: newPtr)
        } else if let oldPtr = delta.pointee.old_file.path {
            path = String(cString: oldPtr)
        } else {
            path = ""
        }
        if let target = targetFilePath {
            // P2-#12 fix: 标准化路径比较 — 去掉前导 ./ 和尾部 /，避免路径不匹配导致"无差异"
            let normalizedPath = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            let normalizedTarget = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
            isCollecting = (normalizedPath == normalizedTarget)
        } else {
            isCollecting = true
        }
    }

    func onHunk(hunk: UnsafePointer<git_diff_hunk>) {
        guard isCollecting else { return }
        let h = hunk.pointee
        hunks.append(GitDiffHunk(
            oldStart: Int(h.old_start), oldLines: Int(h.old_lines),
            newStart: Int(h.new_start), newLines: Int(h.new_lines), lines: []
        ))
        currentHunkIndex = hunks.count - 1
    }

    func onLine(line: UnsafePointer<git_diff_line>) {
        guard isCollecting else { return }
        guard currentHunkIndex >= 0, currentHunkIndex < hunks.count else { return }

        let l = line.pointee
        let lineType: GitDiffLineType
        switch l.origin {
        case Int8(UInt8(ascii: "+")): lineType = .addition
        case Int8(UInt8(ascii: "-")): lineType = .deletion
        case Int8(UInt8(ascii: " ")): lineType = .context
        default: return
        }

        var contentString = ""
        if let content = l.content {
            // CChar is Int8; String(bytes:) needs UInt8 — cast via raw memory
            let count = l.content_len
            let buffer = UnsafeRawBufferPointer(start: content, count: count)
            if let data = Data(bytes: buffer) as Data? {
                if let fullString = String(data: data, encoding: .utf8) {
                    contentString = String(fullString.dropFirst())
                }
            }
        }

        hunks[currentHunkIndex].lines.append(GitDiffLine(
            type: lineType, content: contentString,
            oldLineNumber: l.old_lineno >= 0 ? Int(l.old_lineno) : nil,
            newLineNumber: l.new_lineno >= 0 ? Int(l.new_lineno) : nil
        ))
    }

    func buildRawPatch(filePath: String) -> String {
        var patch = "diff --git a/\(filePath) b/\(filePath)\n"
        for hunk in hunks {
            patch += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\n"
            for line in hunk.lines { patch += "\(line.type.prefix)\(line.content)\n" }
        }
        return patch
    }
}

// MARK: - GitStashCollector

/// Stash 收集器 — 通过 git_stash_foreach 回调收集 stash 条目
/// 使用 class（引用类型）以便通过 payload 指针在 C 回调中访问
final class GitStashCollector {
    var entries: [GitStashEntry] = []
    let repo: OpaquePointer

    init(repo: OpaquePointer) {
        self.repo = repo
    }
}

// MARK: - GitCloneProgressPayload

/// Clone 进度载荷 — 传递给 libgit2 fetch 回调的 username + token + 进度状态
/// 使用 class（引用类型）以便通过 Unmanaged 传递 opaque pointer
final class GitCloneProgressPayload {
    let username: String
    let token: String
    var progress: Double = 0
    var statusText: String = ""

    init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

// MARK: - GitService

/// Git 核心服务 — actor 封装 libgit2 C API
actor GitService {

    private let repositoryPath: String
    private let keychainService: KeychainService

    /// libgit2 初始化返回值（>= 1 成功，< 0 失败）
    /// 必须在任何 libgit2 API 调用前完成初始化
    private let libgit2InitResult: Int32

    init(repositoryPath: String, keychainService: KeychainService) {
        self.repositoryPath = repositoryPath
        self.keychainService = keychainService

        // CRITICAL: 必须在任何 libgit2 调用前初始化库
        // git_libgit2_init() 返回引用计数（>= 1 成功，< 0 失败），线程安全可多次调用
        self.libgit2InitResult = git_libgit2_init()
    }

    // MARK: - Helpers

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

    private func openRepository() throws -> OpaquePointer {
        // 检查 libgit2 是否初始化成功
        guard libgit2InitResult >= 0 else {
            throw GitError.libgit2Error(
                code: libgit2InitResult,
                message: "libgit2 has not been initialized; you must call git_libgit2_init"
            )
        }

        var repo: OpaquePointer? = nil
        let code = git_repository_open(&repo, repositoryPath)
        if code != 0 {
            if code == GIT_ENOTFOUND.rawValue { throw GitError.notAGitRepository }
            try checkGit(code, operation: "git_repository_open")
        }
        guard let handle = repo else { throw GitError.notAGitRepository }
        return handle
    }

    /// Peel a reference to get the target object, then lookup commit by OID
    private func getHeadCommitHandle(repo: OpaquePointer) throws -> OpaquePointer {
        var headRef: OpaquePointer? = nil
        let refCode = git_repository_head(&headRef, repo)
        // GIT_ENOTFOUND (-3): HEAD reference not found
        // GIT_EUNBORNBRANCH (-9): HEAD points to unborn branch (empty repo, no commits yet)
        if refCode == GIT_ENOTFOUND.rawValue || refCode == -9 {
            throw GitError.emptyRepository
        }
        try checkGit(refCode, operation: "git_repository_head")
        defer { git_reference_free(headRef) }

        var peeledObj: OpaquePointer? = nil
        try checkGit(git_reference_peel(&peeledObj, headRef, GIT_OBJECT_COMMIT), operation: "git_reference_peel")
        defer { git_object_free(peeledObj) }
        guard let obj = peeledObj else { throw GitError.emptyRepository }

        let oidPtr = git_object_id(obj)
        var commit: OpaquePointer? = nil
        try checkGit(git_commit_lookup(&commit, repo, oidPtr), operation: "git_commit_lookup")
        guard let commitHandle = commit else {
            throw GitError.operationFailed("HEAD commit lookup returned nil")
        }
        return commitHandle
    }

    /// Get HEAD tree (caller must git_tree_free)
    private func getHeadTree(repo: OpaquePointer) throws -> OpaquePointer {
        let commitHandle = try getHeadCommitHandle(repo: repo)
        defer { git_commit_free(commitHandle) }

        let treeOid = git_commit_tree_id(commitHandle)
        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, treeOid), operation: "git_tree_lookup")
        guard let treeHandle = tree else {
            throw GitError.operationFailed("Tree lookup returned nil")
        }
        return treeHandle
    }

    private func getCurrentBranchName(repo: OpaquePointer) throws -> String {
        var headRef: OpaquePointer? = nil
        let code = git_repository_head(&headRef, repo)
        // GIT_ENOTFOUND (-3): HEAD doesn't exist (detached or no repo)
        if code == GIT_ENOTFOUND.rawValue { return "HEAD (detached)" }
        // GIT_EUNBORNBRANCH (-9): HEAD points to unborn branch (empty repo, no commits yet)
        // 空仓库的 HEAD 指向 refs/heads/master 但 master 尚不存在，返回默认分支名而非报错
        if code == -9 { return "master" }
        try checkGit(code, operation: "git_repository_head")
        defer { git_reference_free(headRef) }

        // Use git_reference_shorthand to get branch name directly (avoids git_buf type issues)
        if let shorthand = git_reference_shorthand(headRef) {
            return String(cString: shorthand)
        }
        return "HEAD"
    }

    private func extractPath(from delta: UnsafeMutablePointer<git_diff_delta>?, isNew: Bool) -> String {
        guard let delta = delta else { return "(unknown)" }
        let pathPtr = isNew ? delta.pointee.new_file.path : delta.pointee.old_file.path
        if let path = pathPtr { return String(cString: path) }
        return "(unknown)"
    }

    // MARK: - Init Repository

    /// 在当前工作目录初始化一个新的 Git 仓库（git_repository_init）
    /// 用于首次打开 Git Tab 时工作目录尚未包含 .git 的情况
    func initRepository() async throws {
        guard libgit2InitResult >= 0 else {
            throw GitError.libgit2Error(
                code: libgit2InitResult,
                message: "libgit2 has not been initialized; you must call git_libgit2_init"
            )
        }

        var repo: OpaquePointer? = nil
        let code = git_repository_init(&repo, repositoryPath, 0)
        if code != 0 {
            try checkGit(code, operation: "git_repository_init")
        }
        if let handle = repo {
            git_repository_free(handle)
        }
    }

    /// 检查当前 repositoryPath 是否已是一个 Git 仓库
    func isGitRepository() async -> Bool {
        guard libgit2InitResult >= 0 else { return false }
        var repo: OpaquePointer? = nil
        let code = git_repository_open(&repo, repositoryPath)
        if code == 0, let handle = repo {
            git_repository_free(handle)
            return true
        }
        return false
    }

    // MARK: - Status

    func status() async throws -> GitStatus {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        let branchName = try getCurrentBranchName(repo: repo)

        var opts = git_status_options()
        git_status_init_options(&opts, numericCast(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        // Set flags as raw bitmask via memory rebinding (enum type is signed in C but values are unsigned)
        let flagsRaw = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        withUnsafeMutablePointer(to: &opts.flags) { ptr in
            ptr.withMemoryRebound(to: type(of: flagsRaw).self, capacity: 1) { rawPtr in
                rawPtr.pointee = flagsRaw
            }
        }

        var statusList: OpaquePointer? = nil
        try checkGit(git_status_list_new(&statusList, repo, &opts), operation: "git_status_list_new")
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)
        var modified: [GitFileStatus] = []
        var staged: [GitFileStatus] = []
        var untracked: [GitFileStatus] = []

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let flags = entry.pointee.status

            if flags.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0 {
                staged.append(GitFileStatus(path: extractPath(from: entry.pointee.head_to_index, isNew: true), changeStatus: .added, isStaged: true))
            } else if flags.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 {
                staged.append(GitFileStatus(path: extractPath(from: entry.pointee.head_to_index, isNew: false), changeStatus: .modified, isStaged: true))
            } else if flags.rawValue & GIT_STATUS_INDEX_DELETED.rawValue != 0 {
                staged.append(GitFileStatus(path: extractPath(from: entry.pointee.head_to_index, isNew: false), changeStatus: .deleted, isStaged: true))
            } else if flags.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue != 0 {
                staged.append(GitFileStatus(path: extractPath(from: entry.pointee.head_to_index, isNew: true), changeStatus: .renamed, isStaged: true))
            }

            if flags.rawValue & GIT_STATUS_WT_NEW.rawValue != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: true)
                // Bug fix (P0): libgit2 的 git_status_list 会列出未追踪的目录（路径以 "/" 结尾，
                // 如 ".baize/"）。git_index_add_bypath 只能暂存文件不能暂存目录，
                // 所以过滤掉目录条目，避免 UI 显示目录后用户点击暂存报错。
                if !path.hasSuffix("/") {
                    untracked.append(GitFileStatus(path: path, changeStatus: .untracked, isStaged: false))
                }
            } else if flags.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 {
                modified.append(GitFileStatus(path: extractPath(from: entry.pointee.index_to_workdir, isNew: false), changeStatus: .modified, isStaged: false))
            } else if flags.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 {
                modified.append(GitFileStatus(path: extractPath(from: entry.pointee.index_to_workdir, isNew: false), changeStatus: .deleted, isStaged: false))
            } else if flags.rawValue & GIT_STATUS_WT_RENAMED.rawValue != 0 {
                modified.append(GitFileStatus(path: extractPath(from: entry.pointee.index_to_workdir, isNew: true), changeStatus: .renamed, isStaged: false))
            }
        }

        return GitStatus(modified: modified, staged: staged, untracked: untracked, currentBranch: branchName)
    }

    // MARK: - Diff

    func diff(filePath: String, diffType: GitDiffType) async throws -> GitDiffResult {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var diff: OpaquePointer? = nil
        var diffOpts = git_diff_options()
        git_diff_init_options(&diffOpts, numericCast(GIT_DIFF_OPTIONS_VERSION))

        switch diffType {
        case .workingTreeVsIndex:
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            try checkGit(git_diff_index_to_workdir(&diff, repo, index, &diffOpts), operation: "git_diff_index_to_workdir")
        case .indexVsHead:
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            try checkGit(git_diff_tree_to_index(&diff, repo, headTree, index, &diffOpts), operation: "git_diff_tree_to_index")
        }
        defer { git_diff_free(diff) }

        let collector = GitDiffCollector()
        collector.targetFilePath = filePath
        let payload = Unmanaged.passUnretained(collector).toOpaque()

        let fileCb: git_diff_file_cb = { delta, _, payload in
            guard let payload = payload, let delta = delta else { return 0 }
            Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onFile(delta: delta)
            return 0
        }
        let hunkCb: git_diff_hunk_cb = { _, hunk, payload in
            guard let payload = payload, let hunk = hunk else { return 0 }
            Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onHunk(hunk: hunk)
            return 0
        }
        let lineCb: git_diff_line_cb = { _, _, line, payload in
            guard let payload = payload, let line = line else { return 0 }
            Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onLine(line: line)
            return 0
        }

        try checkGit(git_diff_foreach(diff, fileCb, nil, hunkCb, lineCb, payload), operation: "git_diff_foreach")

        return GitDiffResult(filePath: filePath, diffType: diffType, hunks: collector.hunks, rawPatch: collector.buildRawPatch(filePath: filePath))
    }

    // MARK: - Stage

    func stage(filePath: String) async throws {
        // Bug fix (P0): 防御性检查 — 如果 filePath 以 "/" 结尾说明是目录，
        // git_index_add_bypath 只能暂存文件不能暂存目录，返回 -1 会报错。
        // 正常情况下 status() 已过滤目录条目，这里是额外的安全防线。
        if filePath.hasSuffix("/") {
            throw GitError.stageFailed("不能暂存目录，请暂存具体文件")
        }

        // Bug fix (P0, round 6): 路径规范化 — 去掉可能的前导 ./
        var normalizedPath = filePath
        if normalizedPath.hasPrefix("./") {
            normalizedPath = String(normalizedPath.dropFirst(2))
        }

        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // Bug fix (P0, round 6): 防御性检查 — 确认文件在磁盘上存在
        let fullPath = (repositoryPath as NSString).appendingPathComponent(normalizedPath)
        if !FileManager.default.fileExists(atPath: fullPath) {
            throw GitError.stageFailed("文件不存在: \(fullPath)（请确认文件已写入磁盘后重试）")
        }

        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }
        guard index != nil else { throw GitError.operationFailed("git_repository_index 返回 nil index") }

        let code = normalizedPath.withCString { git_index_add_bypath(index, $0) }
        if code != 0 {
            // Fallback: 尝试 git_index_add_all（pathspec 匹配）
            let cPath = strdup(normalizedPath)
            var pathStrings: [UnsafeMutablePointer<CChar>?] = [cPath]
            var pathspec = git_strarray(strings: &pathStrings, count: 1)
            let fallbackCode = git_index_add_all(index, &pathspec, 0, nil, nil)
            if let p = cPath { free(p) }
            try checkGit(fallbackCode, operation: "git_index_add_all (fallback for \(normalizedPath))")
        }
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    func stageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }
        guard index != nil else { throw GitError.operationFailed("git_repository_index 返回 nil index") }

        var pathspec = git_strarray(strings: nil, count: 0)
        try checkGit(git_index_add_all(index, &pathspec, 0, nil, nil), operation: "git_index_add_all")
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    // MARK: - Unstage

    func unstage(filePath: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        do {
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }
            let cPath = strdup(filePath)
            defer { free(cPath) }
            var pathStrings: [UnsafeMutablePointer<CChar>?] = [cPath]
            var pathspec = git_strarray(strings: &pathStrings, count: 1)
            let code = git_reset_default(repo, headTree, &pathspec)
            if code != 0 {
                var index: OpaquePointer? = nil
                _ = git_repository_index(&index, repo)
                if let idx = index {
                    let rc = git_index_remove_bypath(idx, cPath)
                    if rc == 0 { _ = git_index_write(idx) }
                    git_index_free(idx)
                    if rc != 0 { throw GitError.stageFailed("unstage failed for '\(filePath)'") }
                } else { throw GitError.stageFailed("unstage failed for '\(filePath)'") }
            }
        } catch GitError.emptyRepository {
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            guard index != nil else { throw GitError.operationFailed("git_repository_index 返回 nil index") }
            let rc = filePath.withCString { git_index_remove_bypath(index, $0) }
            if rc != 0 { throw GitError.stageFailed("unstage failed for '\(filePath)' in empty repo") }
            try checkGit(git_index_write(index), operation: "git_index_write")
        }
    }

    func unstageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        do {
            let headTree = try getHeadTree(repo: repo)
            defer { git_tree_free(headTree) }
            var pathspec = git_strarray(strings: nil, count: 0)
            let code = git_reset_default(repo, headTree, &pathspec)
            if code != 0 { throw GitError.stageFailed("unstageAll failed (code: \(code))") }
        } catch GitError.emptyRepository {
            var index: OpaquePointer? = nil
            try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
            defer { git_index_free(index) }
            guard index != nil else { throw GitError.operationFailed("git_repository_index 返回 nil index") }
            var pathspec = git_strarray(strings: nil, count: 0)
            _ = git_index_remove_all(index, &pathspec, nil, nil)
            try checkGit(git_index_write(index), operation: "git_index_write")
        }
    }

    // MARK: - Commit

    func commit(message: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // Create signature — git_signature is a full struct, not opaque
        var sig: UnsafeMutablePointer<git_signature>? = nil
        let authorName = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? BaizeGit.defaultCommitAuthor
        let authorEmail = BaizeGit.defaultCommitEmail
        let sigCode = authorName.withCString { namePtr in
            authorEmail.withCString { emailPtr in
                git_signature_now(&sig, namePtr, emailPtr)
            }
        }
        try checkGit(sigCode, operation: "git_signature_now")
        defer { git_signature_free(sig) }
        guard let signature = sig else { throw GitError.commitFailed("Signature creation returned nil") }

        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }
        guard index != nil else { throw GitError.operationFailed("git_repository_index 返回 nil index") }

        var treeOid = git_oid()
        try checkGit(git_index_write_tree(&treeOid, index), operation: "git_index_write_tree")

        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, &treeOid), operation: "git_tree_lookup")
        defer { git_tree_free(tree) }

        do {
            let parentCommit = try getHeadCommitHandle(repo: repo)
            defer { git_commit_free(parentCommit) }
            var commitOid = git_oid()
            var parents: [OpaquePointer?] = [parentCommit]
            try checkGit(message.withCString { msgPtr in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, msgPtr, tree, 1, &parents)
            }, operation: "git_commit_create")
        } catch GitError.emptyRepository {
            // 空仓库首次提交（unborn HEAD）—— 无 parent commit
            var commitOid = git_oid()
            try checkGit(message.withCString { msgPtr in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, msgPtr, tree, 0, nil)
            }, operation: "git_commit_create (initial)")
        }
    }

    // MARK: - Push

    /// 检查是否已配置远程仓库（origin）
    /// Bug fix (P1): 新增方法，用于 push 前检查 remote 是否存在
    func hasRemote() async -> Bool {
        guard libgit2InitResult >= 0 else { return false }
        do {
            let repo = try openRepository()
            defer { git_repository_free(repo) }
            var remote: OpaquePointer? = nil
            let code = git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName)
            if let r = remote { git_remote_free(r) }
            return code == 0
        } catch {
            return false
        }
    }

    /// 设置远程仓库地址（创建或更新 origin）
    /// 当用户在设置中保存远程 URL 时调用，将 remote 写入本地 .git/config
    /// Bug fix (P0, round 6): 修复架构缺陷 — 之前 saveConfig() 只存 URL 到 UserDefaults，
    /// 从未调用 git_remote_create 写入 .git/config，导致 push() 时找不到 remote。
    ///
    /// libgit2 v1.3.1 API:
    /// - git_remote_set_url(repo, name, url) — 更新已存在 remote 的 URL（操作 config，非 handle）
    /// - git_remote_create(&out, repo, name, url) — 创建新 remote
    func setRemoteURL(_ url: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 检查 remote 是否已存在
        var remote: OpaquePointer? = nil
        let lookupCode = git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName)

        if lookupCode == 0 && remote != nil {
            // Remote 已存在 — 释放 handle，通过 config API 更新 URL
            git_remote_free(remote)
            try checkGit(
                url.withCString { urlPtr in
                    BaizeGit.defaultRemoteName.withCString { namePtr in
                        git_remote_set_url(repo, namePtr, urlPtr)
                    }
                },
                operation: "git_remote_set_url"
            )
        } else {
            // Remote 不存在 — 释放可能残留的 handle，创建新的
            if let r = remote { git_remote_free(r) }
            var newRemote: OpaquePointer? = nil
            try checkGit(
                url.withCString { urlPtr in
                    BaizeGit.defaultRemoteName.withCString { namePtr in
                        git_remote_create(&newRemote, repo, namePtr, urlPtr)
                    }
                },
                operation: "git_remote_create"
            )
            if let nr = newRemote { git_remote_free(nr) }
        }
    }

    func push(force: Bool = false) async throws {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else { throw GitError.credentialsMissing }
        let username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? "git"

        let repo = try openRepository()
        defer { git_repository_free(repo) }
        let branchName = try getCurrentBranchName(repo: repo)

        var remote: OpaquePointer? = nil
        // Bug fix (P1): 提前检查 remote 是否存在，给出友好提示而非 libgit2 原始错误。
        // Bug fix (P0, round 6): 若 remote 不存在但用户已配 URL，自动注册 remote 再 push。
        // 这修复了"用户在设置中保存了 Token+URL 但 push 报 remote 未配置"的架构缺陷：
        // saveConfig() 之前只存了 URL 到 UserDefaults，未调用 git_remote_create 写入 .git/config。
        let lookupCode = git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName)
        if lookupCode != 0 {
            // 尝试从 UserDefaults 取出之前保存的 URL 自动注册
            if let savedURL = UserDefaults.standard.string(forKey: BaizeGit.remoteURLUDKey), !savedURL.isEmpty {
                // 先释放失败的 lookup 结果（通常为 nil，但安全起见）
                if let r = remote { git_remote_free(r); remote = nil }

                let createCode = savedURL.withCString { urlPtr in
                    BaizeGit.defaultRemoteName.withCString { namePtr in
                        git_remote_create(&remote, repo, namePtr, urlPtr)
                    }
                }
                if createCode != 0 {
                    let detail: String
                    if let err = git_error_last(), let msg = err.pointee.message {
                        detail = String(cString: msg)
                    } else {
                        detail = "unknown"
                    }
                    throw GitError.operationFailed(
                        "远程仓库未配置，且自动创建失败 (\(detail))。请在设置中重新保存 Git 配置。"
                    )
                }
            } else {
                throw GitError.operationFailed("尚未配置远程仓库，请在设置 → Git 配置中添加远程地址")
            }
        }
        defer { if let r = remote { git_remote_free(r) } }

        // B03 fix: force push 时跳过所有预检查（headCommitExists, stagedDiff, remoteRef 比对）
        // force push 的语义是强制覆盖远程，不需要检查是否有新提交或是否已同步
        if !force {
            // Bug fix (P0, round 7): 推送前检查是否有可推送的 commit。
            // 空仓库（unborn HEAD，无任何提交）时，refs/heads/<branch> 不存在，
            // push "refs/heads/master:refs/heads/master" 会报错：
            // "src refspec 'refs/heads/master' does not match any existing object"
            // 此检查给用户清晰的引导，而非底层 libgit2 错误。
            var headCommitExists = false
            var headRef: OpaquePointer? = nil
            let headCode = git_repository_head(&headRef, repo)
            if headCode == 0, let hr = headRef {
                defer { git_reference_free(hr) }
                // HEAD 存在 —— 检查是否能 peel 到 commit 对象
                var peeledObj: OpaquePointer? = nil
                let peelCode = git_reference_peel(&peeledObj, hr, GIT_OBJECT_COMMIT)
                if peelCode == 0, let obj = peeledObj {
                    git_object_free(obj)
                    headCommitExists = true
                }
            }
            // headCode == -9 (GIT_EUNBORNBRANCH): 空仓库，HEAD 指向 unborn branch
            // headCode == -3 (GIT_ENOTFOUND): HEAD 不存在
            // 这两种情况都意味着没有可推送的 commit

            guard headCommitExists else {
                throw GitError.pushFailed(
                    "没有可推送的提交。\n\n请按以下步骤操作：\n"
                    + "1. 在「改动」Tab 点击 ➕ 暂存文件\n"
                    + "2. 输入提交消息后点「提交」\n"
                    + "3. 提交成功后再点 ↑ 推送\n\n"
                    + "（推送需要至少一个 commit 才能创建远程分支）"
                )
            }

            // Bug 4 fix: 推送前检查是否有已暂存但未提交的更改
            // 用户常见误操作：stage 后直接 push，跳过了 commit 步骤
            // 此时 push 会推送旧的 HEAD commit，远程看不到新改动
            do {
                let headTree = try getHeadTree(repo: repo)
                defer { git_tree_free(headTree) }

                var index: OpaquePointer? = nil
                try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
                defer { git_index_free(index) }

                var stagedDiff: OpaquePointer? = nil
                let diffCode = git_diff_tree_to_index(&stagedDiff, repo, headTree, index, nil)
                if diffCode == 0, let d = stagedDiff {
                    let stagedCount = git_diff_num_deltas(d)
                    git_diff_free(d)
                    if stagedCount > 0 {
                        throw GitError.pushFailed(
                            "检测到 \(stagedCount) 个已暂存但未提交的更改。\n\n"
                            + "请先提交更改后再推送：\n"
                            + "1. 输入提交消息\n"
                            + "2. 点击「提交」按钮\n"
                            + "3. 提交成功后再点 ↑ 推送\n\n"
                            + "（push 只推送已 commit 的更改，暂存区的更改不会被推送）"
                        )
                    }
                }
            } catch GitError.emptyRepository {
                // 空仓库已被 headCommitExists 检查拦截，不会到达此处
            }

            // Bug 4 fix: 检查本地 HEAD 是否与远程跟踪分支一致（没有新提交可推送）
            // 如果一致，说明用户没有新 commit，push 是 no-op
            let remoteTrackingRefName = "refs/remotes/\(BaizeGit.defaultRemoteName)/\(branchName)"
            var remoteRef: OpaquePointer? = nil
            let refLookupCode = git_reference_lookup(&remoteRef, repo, remoteTrackingRefName)
            if refLookupCode == 0, let rr = remoteRef {
                defer { git_reference_free(rr) }

                // 获取远程跟踪分支指向的 commit OID
                if let remoteOidPtr = git_reference_target(rr) {

                    // 获取本地 HEAD commit OID
                    var headRef2: OpaquePointer? = nil
                    let headCode2 = git_repository_head(&headRef2, repo)
                    if headCode2 == 0, let hr2 = headRef2 {
                        defer { git_reference_free(hr2) }
                        var headObj2: OpaquePointer? = nil
                        let peelCode2 = git_reference_peel(&headObj2, hr2, GIT_OBJECT_COMMIT)
                        if peelCode2 == 0, let ho2 = headObj2 {
                            defer { git_object_free(ho2) }
                            // 比较两个 OID — 如果相等，说明没有新提交可推送
                            if let localOidPtr = git_object_id(ho2),
                               git_oid_equal(remoteOidPtr, localOidPtr) != 0 {
                                throw GitError.pushFailed(
                                    "本地与远程已同步，没有需要推送的新提交。\n\n"
                                    + "请先提交更改后再推送：\n"
                                    + "1. 暂存文件改动\n"
                                    + "2. 输入提交消息并提交\n"
                                    + "3. 提交成功后再推送\n\n"
                                    + "（当前本地 HEAD 与远程跟踪分支指向同一个 commit）"
                                )
                            }
                        }
                    }
                }
            } else {
                if let r = remoteRef { git_reference_free(r) }
                // 远程跟踪分支不存在 — 首次推送，继续执行
            }
        } // end if !force

        var pushOpts = git_push_options()
        git_push_init_options(&pushOpts, numericCast(GIT_PUSH_OPTIONS_VERSION))

        let payload = GitCredentialsPayload(username: username, token: token)
        let payloadPointer = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<GitCredentialsPayload>.fromOpaque(payloadPointer).release() }

        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, numericCast(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.credentials = credentialsCallback
        callbacks.payload = payloadPointer
        pushOpts.callbacks = callbacks

        // B03 fix: force push 时 refspec 前缀加 +，告诉 libgit2 强制更新远程引用
        let refspec = force
            ? "+refs/heads/\(branchName):refs/heads/\(branchName)"
            : "refs/heads/\(branchName):refs/heads/\(branchName)"
        let cRefspec = strdup(refspec)
        defer { free(cRefspec) }
        var refspecPtrs: [UnsafeMutablePointer<CChar>?] = [cRefspec]
        var refs = git_strarray(strings: &refspecPtrs, count: 1)

        let pushCode = git_remote_push(remote, &refs, &pushOpts)
        if pushCode != 0 {
            let errMsg: String
            if let errPtr = git_error_last() {
                errMsg = errPtr.pointee.message.map { String(cString: $0) } ?? "Unknown error"
            } else { errMsg = "Unknown error" }
            throw GitError.pushFailed(errMsg)
        }
    }

    private let credentialsCallback: git_credential_acquire_cb = { out, _, _, _, payload in
        guard let payload = payload else { return -1 }
        let creds = Unmanaged<GitCredentialsPayload>.fromOpaque(payload).takeUnretainedValue()
        return creds.username.withCString { u in
            creds.token.withCString { t in git_credential_userpass_plaintext_new(out, u, t) }
        }
    }

    // MARK: - Log

    func log(limit: Int = BaizeGit.defaultLogLimit, skip: Int = 0) async throws -> [GitCommit] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var walker: OpaquePointer? = nil
        try checkGit(git_revwalk_new(&walker, repo), operation: "git_revwalk_new")
        defer { git_revwalk_free(walker) }

        // Bug fix (P0): git_revwalk_push_head() 在空仓库（unborn HEAD）时可能返回
        // -1（通用错误）、-3（GIT_ENOTFOUND）或 -9（GIT_EUNBORNBRANCH）。
        // 任何负值都表示 HEAD 无法 push 到 revwalk，对 UI 来说等同于"无提交历史"。
        // 之前只 catch 了 -3 和 -9，遗漏了 -1，导致空仓库切到"历史"Tab 时弹错误 Alert。
        let pushCode = git_revwalk_push_head(walker)
        if pushCode < 0 {
            return []
        }
        try checkGit(pushCode, operation: "git_revwalk_push_head")
        git_revwalk_sorting(walker, GIT_SORT_TIME.rawValue)

        var commits: [GitCommit] = []
        var skipped = 0
        var oid = git_oid()

        while git_revwalk_next(&oid, walker) == 0 {
            if skipped < skip { skipped += 1; continue }
            if commits.count >= limit { break }

            var commit: OpaquePointer? = nil
            if git_commit_lookup(&commit, repo, &oid) != 0 { continue }
            defer { git_commit_free(commit) }
            guard let ch = commit else { continue }

            let author = git_commit_author(ch)
            let authorName = author != nil ? String(cString: author!.pointee.name) : "Unknown"
            let authorEmail = author != nil ? String(cString: author!.pointee.email) : ""
            let commitTime = author != nil ? author!.pointee.when.time : 0
            let messagePtr = git_commit_message(ch)
            let message = messagePtr != nil ? String(cString: messagePtr!) : ""

            let oidHex = withUnsafePointer(to: &oid) { ptr -> String in
                guard let hex = git_oid_tostr_s(ptr) else { return "" }
                return String(cString: hex)
            }

            commits.append(GitCommit(oid: oidHex, author: authorName, email: authorEmail, date: Date(timeIntervalSince1970: TimeInterval(commitTime)), message: message))
        }
        return commits
    }

    // MARK: - Current Branch

    func currentBranch() async throws -> String {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        return try getCurrentBranchName(repo: repo)
    }

    // MARK: - Test Connection

    func testConnection(token: String, remoteURL: String, username: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: BaizeGit.githubUserAPI)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GitError.networkError("Invalid response") }
            if http.statusCode == 200 { return true }
            if http.statusCode == 401 { throw GitError.credentialsInvalid }
            throw GitError.networkError("GitHub API returned status \(http.statusCode)")
        } catch let e as URLError { throw GitError.networkError(e.localizedDescription) }
        catch let e as GitError { throw e }
        catch { throw GitError.networkError(error.localizedDescription) }
    }

    // MARK: - Branch (P1)

    func listBranches() async throws -> [GitBranch] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        let currentName = try getCurrentBranchName(repo: repo)

        var branches: [GitBranch] = []
        var iter: OpaquePointer? = nil
        try checkGit(git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL), operation: "git_branch_iterator_new")
        defer { git_branch_iterator_free(iter) }

        var ref: OpaquePointer? = nil
        var bt = git_branch_t(GIT_BRANCH_LOCAL.rawValue)
        while git_branch_next(&ref, &bt, iter) == 0 {
            defer { git_reference_free(ref) }
            // Use git_reference_shorthand to get branch name (avoids git_buf type issues)
            if let shorthand = git_reference_shorthand(ref) {
                let name = String(cString: shorthand)
                branches.append(GitBranch(name: name, isCurrent: name == currentName, isRemote: false))
            }
        }
        return branches
    }

    func checkoutBranch(_ name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var branchRef: OpaquePointer? = nil
        try checkGit(git_branch_lookup(&branchRef, repo, name, GIT_BRANCH_LOCAL), operation: "git_branch_lookup")
        defer { git_reference_free(branchRef) }

        var peeledObj: OpaquePointer? = nil
        try checkGit(git_reference_peel(&peeledObj, branchRef, GIT_OBJECT_COMMIT), operation: "git_reference_peel")
        defer { git_object_free(peeledObj) }
        guard let obj = peeledObj else { throw GitError.branchNotFound(name) }
        let oidPtr = git_object_id(obj)

        var targetCommit: OpaquePointer? = nil
        try checkGit(git_commit_lookup(&targetCommit, repo, oidPtr), operation: "git_commit_lookup")
        defer { git_commit_free(targetCommit) }
        guard let commitHandle = targetCommit else { throw GitError.branchNotFound(name) }

        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, numericCast(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = numericCast(GIT_CHECKOUT_SAFE.rawValue)

        // Use git_commit_tree_id + git_tree_lookup instead of git_commit_tree
        let treeOid = git_commit_tree_id(commitHandle)
        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, treeOid), operation: "git_tree_lookup")
        defer { git_tree_free(tree) }
        guard let treeHandle = tree else { throw GitError.branchNotFound(name) }
        try checkGit(git_checkout_tree(repo, treeHandle, &checkoutOpts), operation: "git_checkout_tree")

        let refspec = "refs/heads/\(name)"
        try checkGit(refspec.withCString { git_repository_set_head(repo, $0) }, operation: "git_repository_set_head")
    }

    func createBranch(_ name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        let headCommit = try getHeadCommitHandle(repo: repo)
        defer { git_commit_free(headCommit) }

        var newBranch: OpaquePointer? = nil
        let createCode = name.withCString { git_branch_create(&newBranch, repo, $0, headCommit, 0) }
        try checkGit(createCode, operation: "git_branch_create")
        git_reference_free(newBranch)
        try await checkoutBranch(name)
    }

    // MARK: - Fetch (T02 #1)

    /// 从远程仓库拉取更新（不修改工作区）
    /// 使用 git_remote_fetch + credentialsCallback
    func fetch() async throws -> GitFetchResult {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else {
            throw GitError.credentialsMissing
        }
        let username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? "git"

        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 查找或自动创建远程仓库
        var remote: OpaquePointer? = nil
        let lookupCode = git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName)
        if lookupCode != 0 {
            if let savedURL = UserDefaults.standard.string(forKey: BaizeGit.remoteURLUDKey), !savedURL.isEmpty {
                if let r = remote { git_remote_free(r); remote = nil }
                let createCode = savedURL.withCString { urlPtr in
                    BaizeGit.defaultRemoteName.withCString { namePtr in
                        git_remote_create(&remote, repo, namePtr, urlPtr)
                    }
                }
                try checkGit(createCode, operation: "git_remote_create (fetch auto)")
            } else {
                throw GitError.operationFailed("尚未配置远程仓库，请在设置 → Git 配置中添加远程地址")
            }
        }
        defer { if let r = remote { git_remote_free(r) } }

        // 配置回调（复用 credentialsCallback）
        let payload = GitCredentialsPayload(username: username, token: token)
        let payloadPointer = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<GitCredentialsPayload>.fromOpaque(payloadPointer).release() }

        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, numericCast(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.credentials = credentialsCallback
        callbacks.payload = payloadPointer

        // 配置 fetch 选项
        var fetchOpts = git_fetch_options()
        git_fetch_init_options(&fetchOpts, numericCast(GIT_FETCH_OPTIONS_VERSION))
        fetchOpts.callbacks = callbacks

        // 执行 fetch — refspec: +refs/heads/*:refs/remotes/origin/*
        let refspec = "+refs/heads/*:refs/remotes/\(BaizeGit.defaultRemoteName)/*"
        let cRefspec = strdup(refspec)
        defer { free(cRefspec) }
        var refspecPtrs: [UnsafeMutablePointer<CChar>?] = [cRefspec]
        var refs = git_strarray(strings: &refspecPtrs, count: 1)

        try checkGit(
            git_remote_fetch(remote, &refs, &fetchOpts, nil),
            operation: "git_remote_fetch"
        )

        // 获取统计信息
        let stats = git_remote_stats(remote)
        let receivedBytes: Int
        if let s = stats {
            receivedBytes = Int(s.pointee.received_bytes)
        } else {
            receivedBytes = 0
        }

        return GitFetchResult(updatedBranches: 1, receivedBytes: receivedBytes)
    }

    // MARK: - Pull (T02 #1)

    /// 拉取并合并远程更新到当前分支（fetch + merge）
    /// fast-forward 优先；冲突时返回冲突文件列表
    func pull() async throws -> GitMergeResult {
        // 先执行 fetch
        _ = try await fetch()

        let repo = try openRepository()
        defer { git_repository_free(repo) }

        let branchName = try getCurrentBranchName(repo: repo)
        let remoteTrackingRefName = "refs/remotes/\(BaizeGit.defaultRemoteName)/\(branchName)"

        // 查找远程跟踪分支引用
        var remoteRef: OpaquePointer? = nil
        let refLookupCode = git_reference_lookup(&remoteRef, repo, remoteTrackingRefName)
        if refLookupCode != 0 {
            throw GitError.operationFailed("远程跟踪分支不存在: \(remoteTrackingRefName)")
        }
        defer { git_reference_free(remoteRef) }

        // 从引用创建 annotated commit
        var annotated: OpaquePointer? = nil
        try checkGit(
            git_annotated_commit_from_ref(&annotated, repo, remoteRef),
            operation: "git_annotated_commit_from_ref"
        )
        defer { git_annotated_commit_free(annotated) }

        // 检查是否已经是最新的（HEAD == 远程跟踪分支）
        var headCommit = try getHeadCommitHandle(repo: repo)
        defer { git_commit_free(headCommit) }
        let headOid = git_commit_id(headCommit)
        let remoteOid = git_annotated_commit_id(annotated)

        let isUpToDate = headOid != nil && remoteOid != nil &&
            git_oid_equal(headOid, remoteOid) != 0
        if isUpToDate {
            return GitMergeResult(success: true, conflictFiles: [], isFastForward: true)
        }

        // 执行 merge
        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, numericCast(GIT_MERGE_OPTIONS_VERSION))

        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, numericCast(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = numericCast(GIT_CHECKOUT_SAFE.rawValue)

        var theirHeads: [OpaquePointer?] = [annotated]
        let mergeCode = git_merge(repo, &theirHeads, 1, &mergeOpts, &checkoutOpts)

        if mergeCode < 0 {
            let conflicts = try checkMergeConflicts(repo: repo)
            if !conflicts.isEmpty {
                return GitMergeResult(success: false, conflictFiles: conflicts, isFastForward: false)
            }
            try checkGit(mergeCode, operation: "git_merge")
        }

        // 检查冲突
        let conflicts = try checkMergeConflicts(repo: repo)
        if !conflicts.isEmpty {
            return GitMergeResult(success: false, conflictFiles: conflicts, isFastForward: false)
        }

        // 检查是否为 fast-forward（repository state 应为 NONE）
        let state = git_repository_state(repo)
        let isFF = state == 0 // GIT_REPOSITORY_STATE_NONE

        return GitMergeResult(success: true, conflictFiles: [], isFastForward: isFF)
    }

    // MARK: - Merge (T02 #2)

    /// 将指定分支合并到当前分支
    /// 冲突时返回冲突文件列表
    func merge(branch: String) async throws -> GitMergeResult {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 合并前检查工作区是否干净
        let currentStatus = try await status()
        if currentStatus.hasChanges {
            throw GitError.dirtyWorkingTree
        }

        // 查找要合并的分支
        var branchRef: OpaquePointer? = nil
        try checkGit(
            git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL),
            operation: "git_branch_lookup"
        )
        defer { git_reference_free(branchRef) }

        // 从分支引用创建 annotated commit
        var annotated: OpaquePointer? = nil
        try checkGit(
            git_annotated_commit_from_ref(&annotated, repo, branchRef),
            operation: "git_annotated_commit_from_ref"
        )
        defer { git_annotated_commit_free(annotated) }

        // 执行 merge
        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, numericCast(GIT_MERGE_OPTIONS_VERSION))

        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, numericCast(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = numericCast(GIT_CHECKOUT_SAFE.rawValue)

        var theirHeads: [OpaquePointer?] = [annotated]
        let mergeCode = git_merge(repo, &theirHeads, 1, &mergeOpts, &checkoutOpts)

        if mergeCode < 0 {
            let conflicts = try checkMergeConflicts(repo: repo)
            if !conflicts.isEmpty {
                return GitMergeResult(success: false, conflictFiles: conflicts, isFastForward: false)
            }
            try checkGit(mergeCode, operation: "git_merge")
        }

        // 检查冲突
        let conflicts = try checkMergeConflicts(repo: repo)
        if !conflicts.isEmpty {
            return GitMergeResult(success: false, conflictFiles: conflicts, isFastForward: false)
        }

        // 检查是否为 fast-forward
        let state = git_repository_state(repo)
        let isFF = state == 0 // GIT_REPOSITORY_STATE_NONE

        return GitMergeResult(success: true, conflictFiles: [], isFastForward: isFF)
    }

    // MARK: - Rebase (T02 #3)

    /// 将当前分支 rebase 到指定分支的最新 commit 上
    /// 冲突时中止 rebase 并返回冲突文件列表
    func rebase(branch: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // rebase 前检查工作区是否干净
        let currentStatus = try await status()
        if currentStatus.hasChanges {
            throw GitError.dirtyWorkingTree
        }

        // 查找目标分支（upstream）
        var branchRef: OpaquePointer? = nil
        try checkGit(
            git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL),
            operation: "git_branch_lookup (rebase upstream)"
        )
        defer { git_reference_free(branchRef) }

        // 从分支引用创建 annotated commit（upstream）
        var upstreamAnnotated: OpaquePointer? = nil
        try checkGit(
            git_annotated_commit_from_ref(&upstreamAnnotated, repo, branchRef),
            operation: "git_annotated_commit_from_ref (upstream)"
        )
        defer { git_annotated_commit_free(upstreamAnnotated) }

        // 初始化 rebase（branch=nil 使用 HEAD，upstream=目标分支）
        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, numericCast(GIT_REBASE_OPTIONS_VERSION))

        var rebase: OpaquePointer? = nil
        try checkGit(
            git_rebase_init(&rebase, repo, nil, upstreamAnnotated, nil, &rebaseOpts),
            operation: "git_rebase_init"
        )

        // 不使用 defer { git_rebase_free(rebase) } — 因为 abort 会释放对象
        // 手动管理生命周期

        var hadConflict = false
        var conflictFiles: [String] = []

        // rebase 循环：next + commit
        while true {
            // git_rebase_next 的 out 参数类型是 UnsafeMutablePointer<UnsafeMutablePointer<git_rebase_operation>?>
            // （git_rebase_operation 是 C struct，非 OpaquePointer）
            var operation: UnsafeMutablePointer<git_rebase_operation>? = nil
            let nextCode = git_rebase_next(&operation, rebase)

            if nextCode == GIT_ITEROVER.rawValue {
                // 所有 commit 已重放完毕
                break
            }

            if nextCode < 0 {
                // 错误 — 中止 rebase
                hadConflict = true
                conflictFiles = try checkMergeConflicts(repo: repo)
                git_rebase_abort(rebase)
                if conflictFiles.isEmpty {
                    try checkGit(nextCode, operation: "git_rebase_next")
                }
                break
            }

            // 提交重放的 commit
            var commitOid = git_oid()
            let commitCode = git_rebase_commit(&commitOid, rebase, nil, nil, nil, nil)

            if commitCode == GIT_EAPPLIED.rawValue {
                // 已经应用过 — 跳过
                continue
            }

            if commitCode < 0 {
                // 冲突 — 中止 rebase
                hadConflict = true
                conflictFiles = try checkMergeConflicts(repo: repo)
                git_rebase_abort(rebase)
                if conflictFiles.isEmpty {
                    try checkGit(commitCode, operation: "git_rebase_commit")
                }
                break
            }
        }

        if hadConflict {
            throw GitError.rebaseConflict(conflictFiles)
        }

        // 成功完成 — finish + free
        let finishCode = git_rebase_finish(rebase, nil)
        git_rebase_free(rebase)
        try checkGit(finishCode, operation: "git_rebase_finish")
    }

    /// 中止正在进行的 rebase
    func rebaseAbort() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, numericCast(GIT_REBASE_OPTIONS_VERSION))

        var rebase: OpaquePointer? = nil
        let openCode = git_rebase_open(&rebase, repo, &rebaseOpts)
        if openCode != 0 {
            // 没有正在进行的 rebase — 静默返回
            return
        }

        // git_rebase_abort 会释放 rebase 对象，不要再调用 git_rebase_free
        try checkGit(git_rebase_abort(rebase), operation: "git_rebase_abort")
    }

    // MARK: - Stash (T02 #4)

    /// 贮藏当前工作区和暂存区改动
    func stashPush(message: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 检查工作区是否有改动
        let currentStatus = try await status()
        if !currentStatus.hasChanges {
            throw GitError.operationFailed("没有可暂存的改动")
        }

        // 创建签名
        var sig: UnsafeMutablePointer<git_signature>? = nil
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
            throw GitError.operationFailed("Signature creation returned nil")
        }

        // 执行 stash save
        var stashOid = git_oid()
        let stashCode = message.withCString { msgPtr in
            git_stash_save(&stashOid, repo, signature, msgPtr, 0)
        }
        try checkGit(stashCode, operation: "git_stash_save")
    }

    /// 列出所有贮藏条目
    func stashList() async throws -> [GitStashEntry] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        let collector = GitStashCollector(repo: repo)
        let payload = Unmanaged.passUnretained(collector).toOpaque()

        let stashCallback: git_stash_cb = { index, message, stashId, payload in
            guard let payload = payload else { return 0 }
            let collector = Unmanaged<GitStashCollector>.fromOpaque(payload).takeUnretainedValue()
            let msg = message.map { String(cString: $0) } ?? ""

            // 从 stash commit 获取时间
            var date = Date()
            if let stashId = stashId {
                var commit: OpaquePointer? = nil
                if git_commit_lookup(&commit, collector.repo, stashId) == 0, let ch = commit {
                    let author = git_commit_author(ch)
                    if let a = author {
                        date = Date(timeIntervalSince1970: TimeInterval(a.pointee.when.time))
                    }
                    git_commit_free(ch)
                }
            }

            collector.entries.append(GitStashEntry(
                index: Int(index),
                message: msg,
                date: date
            ))
            return 0
        }

        try checkGit(
            git_stash_foreach(repo, stashCallback, payload),
            operation: "git_stash_foreach"
        )

        return collector.entries
    }

    /// 恢复并删除指定索引的贮藏
    /// 冲突时保留 stash 不删除
    func stashPop(index: Int) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var applyOpts = git_stash_apply_options()
        git_stash_apply_init_options(&applyOpts, numericCast(GIT_STASH_APPLY_OPTIONS_VERSION))

        let popCode = git_stash_pop(repo, numericCast(index), &applyOpts)
        if popCode < 0 {
            // 检查是否为冲突
            let conflicts = try checkMergeConflicts(repo: repo)
            if !conflicts.isEmpty {
                throw GitError.mergeConflict(conflicts)
            }
            try checkGit(popCode, operation: "git_stash_pop")
        }
    }

    /// 删除指定索引的贮藏（不恢复）
    func stashDrop(index: Int) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        try checkGit(
            git_stash_drop(repo, numericCast(index)),
            operation: "git_stash_drop"
        )
    }

    // MARK: - Reset (T02 #5)

    /// 重置到指定 commit（soft / mixed / hard）
    func reset(to oid: String, mode: GitResetMode) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 解析 OID 字符串
        var targetOid = git_oid()
        try checkGit(
            oid.withCString { git_oid_fromstr(&targetOid, $0) },
            operation: "git_oid_fromstr"
        )

        // 查找目标 commit
        var target: OpaquePointer? = nil
        try checkGit(
            git_object_lookup(&target, repo, &targetOid, GIT_OBJECT_COMMIT),
            operation: "git_object_lookup"
        )
        defer { git_object_free(target) }
        guard let targetObj = target else {
            throw GitError.operationFailed("Reset target commit not found: \(oid)")
        }

        // 配置 checkout 选项（hard 模式需要 FORCE）
        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, numericCast(GIT_CHECKOUT_OPTIONS_VERSION))
        if mode == .hard {
            checkoutOpts.checkout_strategy = numericCast(GIT_CHECKOUT_FORCE.rawValue)
        } else {
            checkoutOpts.checkout_strategy = numericCast(GIT_CHECKOUT_SAFE.rawValue)
        }

        // 映射 reset 模式
        let resetType: git_reset_t
        switch mode {
        case .soft: resetType = GIT_RESET_SOFT
        case .mixed: resetType = GIT_RESET_MIXED
        case .hard: resetType = GIT_RESET_HARD
        }

        try checkGit(
            git_reset(repo, targetObj, resetType, &checkoutOpts),
            operation: "git_reset (\(mode.rawValue))"
        )
    }

    // MARK: - Tag (T02 #6)

    /// 创建标签（附注标签或轻量标签）
    /// - Parameters:
    ///   - name: 标签名
    ///   - message: 标签消息（nil 时创建轻量标签）
    ///   - targetOid: 目标 commit OID（nil 时在 HEAD 创建）
    func createTag(name: String, message: String?, targetOid: String?) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 解析目标 OID
        var oid = git_oid()
        if let targetOid = targetOid, !targetOid.isEmpty {
            try checkGit(
                targetOid.withCString { git_oid_fromstr(&oid, $0) },
                operation: "git_oid_fromstr (tag target)"
            )
        } else {
            // 使用 HEAD
            let headCommit = try getHeadCommitHandle(repo: repo)
            defer { git_commit_free(headCommit) }
            let headOid = git_commit_id(headCommit)
            guard let ho = headOid else {
                throw GitError.emptyRepository
            }
            oid = ho.pointee
        }

        // 查找目标对象
        var target: OpaquePointer? = nil
        try checkGit(
            git_object_lookup(&target, repo, &oid, GIT_OBJECT_COMMIT),
            operation: "git_object_lookup (tag target)"
        )
        defer { git_object_free(target) }
        guard let targetObj = target else {
            throw GitError.operationFailed("Tag target commit not found")
        }

        var tagOid = git_oid()

        if let message = message, !message.isEmpty {
            // 创建附注标签
            var sig: UnsafeMutablePointer<git_signature>? = nil
            let authorName = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? BaizeGit.defaultCommitAuthor
            let authorEmail = BaizeGit.defaultCommitEmail
            let sigCode = authorName.withCString { namePtr in
                authorEmail.withCString { emailPtr in
                    git_signature_now(&sig, namePtr, emailPtr)
                }
            }
            try checkGit(sigCode, operation: "git_signature_now (tag)")
            defer { git_signature_free(sig) }
            guard let signature = sig else {
                throw GitError.operationFailed("Tag signature creation returned nil")
            }

            let createCode = name.withCString { namePtr in
                message.withCString { msgPtr in
                    git_tag_create(&tagOid, repo, namePtr, targetObj, signature, msgPtr, 0)
                }
            }
            if createCode == -4 { // GIT_EEXISTS
                throw GitError.tagExists(name)
            }
            try checkGit(createCode, operation: "git_tag_create")
        } else {
            // 创建轻量标签
            let createCode = name.withCString { namePtr in
                git_tag_create_lightweight(&tagOid, repo, namePtr, targetObj, 0)
            }
            if createCode == -4 { // GIT_EEXISTS
                throw GitError.tagExists(name)
            }
            try checkGit(createCode, operation: "git_tag_create_lightweight")
        }
    }

    /// 列出所有标签
    func listTags() async throws -> [GitTag] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 获取标签名列表
        var tagNames = git_strarray()
        try checkGit(git_tag_list(&tagNames, repo), operation: "git_tag_list")
        defer { git_strarray_free(&tagNames) }

        var tags: [GitTag] = []
        let count = Int(tagNames.count)

        for i in 0..<count {
            guard let namePtr = tagNames.strings?[i] else { continue }
            let name = String(cString: namePtr)

            // 通过引用名查找 OID
            var tagOid = git_oid()
            let refName = "refs/tags/\(name)"
            let lookupCode = refName.withCString { git_reference_name_to_id(&tagOid, repo, $0) }
            guard lookupCode == 0 else { continue }

            let oidHex = withUnsafePointer(to: &tagOid) { ptr -> String in
                guard let hex = git_oid_tostr_s(ptr) else { return "" }
                return String(cString: hex)
            }

            // 尝试查找为附注标签
            var tag: OpaquePointer? = nil
            if git_tag_lookup(&tag, repo, &tagOid) == 0, let tagHandle = tag {
                defer { git_tag_free(tagHandle) }

                let tagger = git_tag_tagger(tagHandle)
                let tagDate: Date
                if let t = tagger {
                    tagDate = Date(timeIntervalSince1970: TimeInterval(t.pointee.when.time))
                } else {
                    tagDate = Date()
                }

                let message = git_tag_message(tagHandle).map { String(cString: $0) }

                tags.append(GitTag(
                    name: name,
                    oid: oidHex,
                    date: tagDate,
                    message: message,
                    isAnnotated: true
                ))
            } else {
                // 轻量标签 — OID 指向 commit
                var commit: OpaquePointer? = nil
                var tagDate = Date()
                if git_commit_lookup(&commit, repo, &tagOid) == 0, let ch = commit {
                    let author = git_commit_author(ch)
                    if let a = author {
                        tagDate = Date(timeIntervalSince1970: TimeInterval(a.pointee.when.time))
                    }
                    git_commit_free(ch)
                }

                tags.append(GitTag(
                    name: name,
                    oid: oidHex,
                    date: tagDate,
                    message: nil,
                    isAnnotated: false
                ))
            }
        }

        return tags.sorted { $0.name < $1.name }
    }

    /// 删除指定标签
    func deleteTag(name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        try checkGit(
            name.withCString { git_tag_delete(repo, $0) },
            operation: "git_tag_delete"
        )
    }

    // MARK: - Clone (T02 #7)

    /// 克隆远程仓库到指定路径
    /// - Parameters:
    ///   - remoteURL: 远程仓库 URL（HTTPS 或 SSH）
    ///   - toPath: 本地目标路径
    ///   - progressHandler: 可选进度回调（0.0–1.0 + 状态文本）
    func clone(remoteURL: String, toPath: String,
               progressHandler: ((Double, String) -> Void)?) async throws {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else {
            throw GitError.credentialsMissing
        }
        let username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? "git"

        // 检查目标目录是否已存在且非空
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: toPath) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: toPath)) ?? []
            if !contents.isEmpty {
                throw GitError.directoryExists(toPath)
            }
        } else {
            // 创建目标目录
            try fileManager.createDirectory(atPath: toPath, withIntermediateDirectories: true)
        }

        // 通知开始
        progressHandler?(0.0, "正在克隆 \(remoteURL)...")

        // 配置 clone 选项
        var cloneOpts = git_clone_options()
        git_clone_options_init(&cloneOpts, numericCast(GIT_CLONE_OPTIONS_VERSION))

        // 配置回调（复用 credentialsCallback）
        let payload = GitCloneProgressPayload(username: username, token: token)
        let payloadPointer = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<GitCloneProgressPayload>.fromOpaque(payloadPointer).release() }

        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, numericCast(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.credentials = credentialsCallback
        callbacks.payload = payloadPointer

        cloneOpts.fetch_opts.callbacks = callbacks

        // 执行 clone
        var clonedRepo: OpaquePointer? = nil
        let cloneCode = remoteURL.withCString { urlPtr in
            toPath.withCString { pathPtr in
                git_clone(&clonedRepo, urlPtr, pathPtr, &cloneOpts)
            }
        }

        if cloneCode < 0 {
            let errMsg: String
            if let errPtr = git_error_last() {
                errMsg = errPtr.pointee.message.map { String(cString: $0) } ?? "Unknown error"
            } else {
                errMsg = "Unknown error"
            }
            throw GitError.cloneFailed(errMsg)
        }

        // 释放 clone 返回的 repository 对象
        if let repo = clonedRepo {
            git_repository_free(repo)
        }

        // 通知完成
        progressHandler?(1.0, "克隆完成")
    }

    // MARK: - Branch Delete / Rename (T02 #8)

    /// 删除本地分支（不能删除当前分支）
    func deleteBranch(name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 检查是否为当前分支
        let currentName = try getCurrentBranchName(repo: repo)
        if name == currentName {
            throw GitError.cannotDeleteCurrentBranch
        }

        // 查找分支
        var branchRef: OpaquePointer? = nil
        let lookupCode = git_branch_lookup(&branchRef, repo, name, GIT_BRANCH_LOCAL)
        if lookupCode == GIT_ENOTFOUND.rawValue {
            throw GitError.branchNotFound(name)
        }
        try checkGit(lookupCode, operation: "git_branch_lookup (delete)")
        defer { git_reference_free(branchRef) }

        // 删除分支
        try checkGit(
            git_branch_delete(branchRef),
            operation: "git_branch_delete"
        )
    }

    /// 重命名分支
    func renameBranch(oldName: String, newName: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 查找分支
        var branchRef: OpaquePointer? = nil
        let lookupCode = git_branch_lookup(&branchRef, repo, oldName, GIT_BRANCH_LOCAL)
        if lookupCode == GIT_ENOTFOUND.rawValue {
            throw GitError.branchNotFound(oldName)
        }
        try checkGit(lookupCode, operation: "git_branch_lookup (rename)")

        // 重命名
        var newRef: OpaquePointer? = nil
        let moveCode = newName.withCString { newNamePtr in
            git_branch_move(&newRef, branchRef, newNamePtr, 0)
        }
        git_reference_free(branchRef)
        if let nr = newRef { git_reference_free(nr) }

        if moveCode == -4 { // GIT_EEXISTS
            throw GitError.operationFailed("分支名已存在: \(newName)")
        }
        try checkGit(moveCode, operation: "git_branch_move")
    }

    // MARK: - Remote Branches (T02 #9)

    /// 列出远程分支（先执行 fetch 确保最新）
    func listRemoteBranches() async throws -> [GitBranch] {
        // 先 fetch 确保远程分支列表是最新的
        _ = try await fetch()

        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var branches: [GitBranch] = []
        var iter: OpaquePointer? = nil
        try checkGit(
            git_branch_iterator_new(&iter, repo, GIT_BRANCH_REMOTE),
            operation: "git_branch_iterator_new (remote)"
        )
        defer { git_branch_iterator_free(iter) }

        var ref: OpaquePointer? = nil
        var bt = git_branch_t(GIT_BRANCH_REMOTE.rawValue)
        while git_branch_next(&ref, &bt, iter) == 0 {
            defer { git_reference_free(ref) }
            if let shorthand = git_reference_shorthand(ref) {
                let name = String(cString: shorthand)
                branches.append(GitBranch(name: name, isCurrent: false, isRemote: true))
            }
        }
        return branches
    }

    /// 检出远程分支（创建本地跟踪分支并切换）
    func checkoutRemoteBranch(name: String) async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 检查工作区是否干净
        let currentStatus = try await status()
        if currentStatus.hasChanges {
            throw GitError.dirtyWorkingTree
        }

        // 处理远程分支名 — 可能带 origin/ 前缀
        let remoteName: String
        let localName: String
        if name.hasPrefix("\(BaizeGit.defaultRemoteName)/") {
            remoteName = name
            localName = String(name.dropFirst(BaizeGit.defaultRemoteName.count + 1))
        } else {
            remoteName = "\(BaizeGit.defaultRemoteName)/\(name)"
            localName = name
        }

        // 检查本地同名分支是否已存在
        var localRef: OpaquePointer? = nil
        let localLookupCode = git_branch_lookup(&localRef, repo, localName, GIT_BRANCH_LOCAL)
        if localLookupCode == 0 {
            git_reference_free(localRef)
            throw GitError.operationFailed("本地分支 '\(localName)' 已存在")
        }
        if let r = localRef { git_reference_free(r) }

        // 查找远程分支
        var remoteRef: OpaquePointer? = nil
        let remoteLookupCode = git_branch_lookup(&remoteRef, repo, remoteName, GIT_BRANCH_REMOTE)
        if remoteLookupCode == GIT_ENOTFOUND.rawValue {
            throw GitError.branchNotFound(remoteName)
        }
        try checkGit(remoteLookupCode, operation: "git_branch_lookup (remote checkout)")
        defer { git_reference_free(remoteRef) }

        // 获取远程分支指向的 commit
        var peeledObj: OpaquePointer? = nil
        try checkGit(
            git_reference_peel(&peeledObj, remoteRef, GIT_OBJECT_COMMIT),
            operation: "git_reference_peel (remote branch)"
        )
        defer { git_object_free(peeledObj) }
        guard let obj = peeledObj else {
            throw GitError.branchNotFound(remoteName)
        }
        let oidPtr = git_object_id(obj)

        var targetCommit: OpaquePointer? = nil
        try checkGit(
            git_commit_lookup(&targetCommit, repo, oidPtr),
            operation: "git_commit_lookup (remote branch target)"
        )
        defer { git_commit_free(targetCommit) }
        guard let commitHandle = targetCommit else {
            throw GitError.branchNotFound(remoteName)
        }

        // 创建本地分支
        var newBranch: OpaquePointer? = nil
        try checkGit(
            localName.withCString { namePtr in
                git_branch_create(&newBranch, repo, namePtr, commitHandle, 0)
            },
            operation: "git_branch_create (from remote)"
        )

        // 设置 upstream 跟踪远程分支
        let upstreamName = "\(BaizeGit.defaultRemoteName)/\(localName)"
        let upstreamCode = upstreamName.withCString { upstreamPtr in
            git_branch_set_upstream(newBranch, upstreamPtr)
        }
        git_reference_free(newBranch)
        try checkGit(upstreamCode, operation: "git_branch_set_upstream")

        // 切换到新创建的本地分支
        try await checkoutBranch(localName)
    }

    // MARK: - B10: List Remotes

    /// 列出所有远程仓库及其 URL（git remote -v）
    func listRemotes() async throws -> [GitRemoteInfo] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        var remotes: git_strarray = git_strarray()
        try checkGit(git_remote_list(&remotes, repo), operation: "git_remote_list")
        defer { git_strarray_free(&remotes) }

        var result: [GitRemoteInfo] = []
        let count = Int(remotes.count)
        for i in 0..<count {
            guard let namePtr = remotes.strings?[i] else { continue }
            let name = String(cString: namePtr)

            var remote: OpaquePointer? = nil
            let lookupCode = git_remote_lookup(&remote, repo, name)
            if lookupCode == 0, let r = remote {
                defer { git_remote_free(r) }
                let urlPtr = git_remote_url(r)
                let url = urlPtr.map { String(cString: $0) } ?? ""
                result.append(GitRemoteInfo(name: name, url: url, type: "fetch/push"))
            }
        }
        return result
    }

    // MARK: - B11: List All Branches (local + remote)

    /// 列出所有分支（本地 + 远程），不执行 fetch
    func listAllBranches() async throws -> [GitBranch] {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        let currentName = try getCurrentBranchName(repo: repo)

        var branches: [GitBranch] = []

        // 本地分支
        var localIter: OpaquePointer? = nil
        try checkGit(
            git_branch_iterator_new(&localIter, repo, GIT_BRANCH_LOCAL),
            operation: "git_branch_iterator_new (local)"
        )
        defer { git_branch_iterator_free(localIter) }

        var ref: OpaquePointer? = nil
        var bt = git_branch_t(GIT_BRANCH_LOCAL.rawValue)
        while git_branch_next(&ref, &bt, localIter) == 0 {
            defer { git_reference_free(ref) }
            if let shorthand = git_reference_shorthand(ref) {
                let name = String(cString: shorthand)
                branches.append(GitBranch(name: name, isCurrent: name == currentName, isRemote: false))
            }
        }

        // 远程分支（不 fetch，直接读已有的 refs/remotes/origin/*）
        var remoteIter: OpaquePointer? = nil
        let remoteIterCode = git_branch_iterator_new(&remoteIter, repo, GIT_BRANCH_REMOTE)
        if remoteIterCode == 0 {
            defer { git_branch_iterator_free(remoteIter) }
            var bt2 = git_branch_t(GIT_BRANCH_REMOTE.rawValue)
            while git_branch_next(&ref, &bt2, remoteIter) == 0 {
                defer { git_reference_free(ref) }
                if let shorthand = git_reference_shorthand(ref) {
                    let name = String(cString: shorthand)
                    branches.append(GitBranch(name: name, isCurrent: false, isRemote: true))
                }
            }
        }

        return branches
    }

    // MARK: - B15: Show Commit

    /// 显示指定 commit 的详情（git show <oid>）
    /// - Parameter oid: commit OID 字符串（nil 或 "HEAD" 时显示最新 commit）
    func show(oid: String? = nil) async throws -> GitShowResult {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        // 解析目标 commit
        var targetOid: git_oid
        if let oid = oid, !oid.isEmpty, oid != "HEAD" {
            targetOid = git_oid()
            try checkGit(
                oid.withCString { git_oid_fromstr(&targetOid, $0) },
                operation: "git_oid_fromstr (show)"
            )
        } else {
            // 使用 HEAD
            let headCommit = try getHeadCommitHandle(repo: repo)
            defer { git_commit_free(headCommit) }
            let headOidPtr = git_commit_id(headCommit)
            guard let ho = headOidPtr else { throw GitError.emptyRepository }
            targetOid = ho.pointee
        }

        // 查找 commit
        var commit: OpaquePointer? = nil
        try checkGit(
            git_commit_lookup(&commit, repo, &targetOid),
            operation: "git_commit_lookup (show)"
        )
        defer { git_commit_free(commit) }
        guard let commitHandle = commit else {
            throw GitError.operationFailed("Commit not found")
        }

        // 提取 commit 信息
        let author = git_commit_author(commitHandle)
        let authorName = author != nil ? String(cString: author!.pointee.name) : "Unknown"
        let authorEmail = author != nil ? String(cString: author!.pointee.email) : ""
        let commitTime = author != nil ? author!.pointee.when.time : 0
        let messagePtr = git_commit_message(commitHandle)
        let message = messagePtr != nil ? String(cString: messagePtr!) : ""

        let oidHex = withUnsafePointer(to: &targetOid) { ptr -> String in
            guard let hex = git_oid_tostr_s(ptr) else { return "" }
            return String(cString: hex)
        }

        // 生成 diff（commit vs 其 parent）
        var patch = ""
        let treeOid = git_commit_tree_id(commitHandle)
        var tree: OpaquePointer? = nil
        try checkGit(git_tree_lookup(&tree, repo, treeOid), operation: "git_tree_lookup (show)")
        defer { git_tree_free(tree) }
        guard let treeHandle = tree else {
            return GitShowResult(oid: oidHex, author: authorName, email: authorEmail,
                                 date: Date(timeIntervalSince1970: TimeInterval(commitTime)),
                                 message: message, patch: "")
        }

        let parentCount = git_commit_parentcount(commitHandle)
        var diff: OpaquePointer? = nil

        if parentCount > 0 {
            // 有 parent — diff parent tree vs commit tree
            let parent = git_commit_parent(commitHandle, 0)
            defer { git_commit_free(parent) }
            if let parentHandle = parent {
                let parentTreeOid = git_commit_tree_id(parentHandle)
                var parentTree: OpaquePointer? = nil
                try checkGit(git_tree_lookup(&parentTree, repo, parentTreeOid), operation: "git_tree_lookup (parent)")
                defer { git_tree_free(parentTree) }
                guard let parentTreeHandle = parentTree else {
                    return GitShowResult(oid: oidHex, author: authorName, email: authorEmail,
                                         date: Date(timeIntervalSince1970: TimeInterval(commitTime)),
                                         message: message, patch: "")
                }

                var diffOpts = git_diff_options()
                git_diff_init_options(&diffOpts, numericCast(GIT_DIFF_OPTIONS_VERSION))
                try checkGit(
                    git_diff_tree_to_tree(&diff, repo, parentTreeHandle, treeHandle, &diffOpts),
                    operation: "git_diff_tree_to_tree (show)"
                )
            }
        } else {
            // 初始 commit — 无 parent tree，无法用 git_diff_tree_to_tree(diff vs nil)
            // 返回 commit 信息但不包含 diff patch
            return GitShowResult(
                oid: oidHex,
                author: authorName,
                email: authorEmail,
                date: Date(timeIntervalSince1970: TimeInterval(commitTime)),
                message: message,
                patch: "(初始提交，无父提交可对比)"
            )
        }

        defer { git_diff_free(diff) }

        if let diffHandle = diff {
            // 收集 diff patch
            let collector = GitDiffCollector()
            let payload = Unmanaged.passUnretained(collector).toOpaque()

            let fileCb: git_diff_file_cb = { delta, _, payload in
                guard let payload = payload, let delta = delta else { return 0 }
                Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onFile(delta: delta)
                return 0
            }
            let hunkCb: git_diff_hunk_cb = { _, hunk, payload in
                guard let payload = payload, let hunk = hunk else { return 0 }
                Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onHunk(hunk: hunk)
                return 0
            }
            let lineCb: git_diff_line_cb = { _, _, line, payload in
                guard let payload = payload, let line = line else { return 0 }
                Unmanaged<GitDiffCollector>.fromOpaque(payload).takeUnretainedValue().onLine(line: line)
                return 0
            }

            _ = git_diff_foreach(diffHandle, fileCb, nil, hunkCb, lineCb, payload)

            // 构建完整 patch
            for hunk in collector.hunks {
                patch += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\n"
                for line in hunk.lines {
                    patch += "\(line.type.prefix)\(line.content)\n"
                }
            }
        }

        return GitShowResult(
            oid: oidHex,
            author: authorName,
            email: authorEmail,
            date: Date(timeIntervalSince1970: TimeInterval(commitTime)),
            message: message,
            patch: patch
        )
    }

    // MARK: - Conflict Detection Helper

    /// 检查 merge/rebase 冲突并返回冲突文件列表
    private func checkMergeConflicts(repo: OpaquePointer) throws -> [String] {
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }

        // 检查是否有冲突
        if git_index_has_conflicts(index) == 0 {
            return []
        }

        // 枚举冲突文件
        var conflictIter: OpaquePointer? = nil
        try checkGit(
            git_index_conflict_iterator_new(&conflictIter, index),
            operation: "git_index_conflict_iterator_new"
        )
        defer { git_index_conflict_iterator_free(conflictIter) }

        var conflictFiles: [String] = []
        var ancestor: UnsafePointer<git_index_entry>? = nil
        var ours: UnsafePointer<git_index_entry>? = nil
        var theirs: UnsafePointer<git_index_entry>? = nil

        while git_index_conflict_next(&ancestor, &ours, &theirs, conflictIter) == 0 {
            if let path = ours?.pointee.path {
                let filePath = String(cString: path)
                if !conflictFiles.contains(filePath) {
                    conflictFiles.append(filePath)
                }
            } else if let path = theirs?.pointee.path {
                let filePath = String(cString: path)
                if !conflictFiles.contains(filePath) {
                    conflictFiles.append(filePath)
                }
            }
        }

        return conflictFiles
    }
}
