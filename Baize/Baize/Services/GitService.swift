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
            isCollecting = (path == target)
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

// MARK: - GitService

/// Git 核心服务 — actor 封装 libgit2 C API
actor GitService {

    private let repositoryPath: String
    private let keychainService: KeychainService

    init(repositoryPath: String, keychainService: KeychainService) {
        self.repositoryPath = repositoryPath
        self.keychainService = keychainService
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
        if refCode == GIT_ENOTFOUND.rawValue { throw GitError.emptyRepository }
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
        if code == GIT_ENOTFOUND.rawValue { return "HEAD (detached)" }
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

    // MARK: - Status

    func status() async throws -> GitStatus {
        let repo = try openRepository()
        defer { git_repository_free(repo) }

        let branchName = try getCurrentBranchName(repo: repo)

        var opts = git_status_options()
        git_status_init_options(&opts, numericCast(GIT_STATUS_OPTIONS_VERSION))
        opts.show = numericCast(GIT_STATUS_SHOW_INDEX_AND_WORKDIR.rawValue)
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
                untracked.append(GitFileStatus(path: extractPath(from: entry.pointee.index_to_workdir, isNew: true), changeStatus: .untracked, isStaged: false))
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
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }
        let code = filePath.withCString { git_index_add_bypath(index, $0) }
        if code != 0 { throw GitError.stageFailed("git_index_add_bypath failed for '\(filePath)' (code: \(code))") }
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    func stageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }
        var pathspec = git_strarray(strings: nil, count: 0)
        let code = git_index_add_all(index, &pathspec, 0, nil, nil)
        if code != 0 { throw GitError.stageFailed("git_index_add_all failed (code: \(code))") }
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
            let createCode = message.withCString { msgPtr in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, msgPtr, tree, 1, &parents)
            }
            try checkGit(createCode, operation: "git_commit_create")
        } catch GitError.emptyRepository {
            var commitOid = git_oid()
            let createCode = message.withCString { msgPtr in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, msgPtr, tree, 0, nil)
            }
            try checkGit(createCode, operation: "git_commit_create (initial)")
        }
    }

    // MARK: - Push

    func push() async throws {
        guard let token = keychainService.loadGitToken(), !token.isEmpty else { throw GitError.credentialsMissing }
        let username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? "git"

        let repo = try openRepository()
        defer { git_repository_free(repo) }
        let branchName = try getCurrentBranchName(repo: repo)

        var remote: OpaquePointer? = nil
        try checkGit(git_remote_lookup(&remote, repo, BaizeGit.defaultRemoteName), operation: "git_remote_lookup")
        defer { git_remote_free(remote) }

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

        let refspec = "refs/heads/\(branchName):refs/heads/\(branchName)"
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
        try checkGit(git_revwalk_push_head(walker), operation: "git_revwalk_push_head")
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
}
