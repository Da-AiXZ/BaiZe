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

    // MARK: - Index Warmup

    /// 预热 index —— 读取 entry count 并写回，强制初始化 index 内部结构。
    ///
    /// Bug fix (P0, round 7): 空仓库首次 index 写入可能触发
    /// "failed to initialize zlib"。通过预先读取 entry count + 写回
    /// 空 index 来初始化内部状态，可能修复 zlib 的延迟初始化问题。
    /// 即使 warmup 本身失败也不阻断后续操作（记录但不 throw）。
    private func warmupIndex(_ index: OpaquePointer) {
        // 1. 读取 entry count —— 触发 index 内部初始化
        _ = git_index_entrycount(index)

        // 2. 尝试写回 index —— 强制初始化 index 文件结构
        //    warmup 失败不阻断主流程，仅记录
        let writeCode = git_index_write(index)
        if writeCode != 0 {
            // warmup 写入失败，不 throw —— 让后续操作自行处理
            // 记录到 Logger（如果可用），否则静默
        }
    }

    // MARK: - Manual Git Object Operations (zlib bypass)

    /// 使用 CommonCrypto 计算 SHA-1 并返回 40 字符十六进制字符串。
    ///
    /// Bug fix (P0, round 7): 当 libgit2 内部 zlib 初始化失败时，
    /// 需要手动创建 git loose objects。SHA-1 是 git 对象 ID 的基础。
    private func sha1Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 使用系统 zlib (libz.tbd) 压缩数据，返回 zlib 格式的压缩数据。
    ///
    /// Bug fix (P0, round 7): libgit2 静态库内部的 zlib 可能因版本不匹配
    /// 导致 deflateInit 失败。此方法直接调用系统 zlib 的 compress2，
    /// 绕过 libgit2 内部的 zlib 封装，用于手动创建 git loose objects。
    /// 返回 nil 表示系统 zlib 也失败了（极端情况）。
    private func zlibCompress(_ data: Data) -> Data? {
        let sourceLen = UInt(data.count)
        let bound = compressBound(sourceLen)
        var destLen = bound
        var destBuffer = [UInt8](repeating: 0, count: Int(bound))

        let result: Int32 = destBuffer.withUnsafeMutableBufferPointer { destPtr in
            data.withUnsafeBytes { sourcePtr in
                compress2(
                    destPtr.baseAddress,
                    &destLen,
                    sourcePtr.bindMemory(to: UInt8.self).baseAddress,
                    sourceLen,
                    Z_DEFAULT_COMPRESSION
                )
            }
        }

        guard result == Z_OK else { return nil }
        return Data(destBuffer.prefix(Int(destLen)))
    }

    /// 手动写入 git loose object，返回对象的 OID（40 字符十六进制 SHA-1）。
    ///
    /// Git loose object 格式：
    /// 1. 对象头：`<type> <size>\0`（如 `blob 13\0`）
    /// 2. 对象内容（文件数据 / 树条目 / 提交信息）
    /// 3. (头 + 内容) 整体用 zlib deflate 压缩
    /// 4. SHA-1(头 + 内容) = 对象 ID
    /// 5. 存储在 `.git/objects/<oid[:2]>/<oid[2:]>`
    ///
    /// 此方法用系统 zlib 压缩，绕过 libgit2 内部可能损坏的 zlib。
    private func writeLooseObject(type: String, content: Data) throws -> String {
        // 1. 构建未压缩对象数据："<type> <size>\0" + content
        var objectData = Data()
        let headerString = "\(type) \(content.count)"
        objectData.append(headerString.data(using: .isoLatin1) ?? Data())
        objectData.append(0) // null 分隔符

        // 2. 附加内容
        objectData.append(contentsOf: content)

        // 3. 计算 SHA-1 —— 这就是 git 对象 ID
        let oidHex = sha1Hex(objectData)

        // 4. 检查对象是否已存在（避免重复写入）
        let objectDir = (repositoryPath as NSString)
            .appendingPathComponent(".git/objects/\(String(oidHex.prefix(2)))")
        let objectPath = (objectDir as NSString)
            .appendingPathComponent(String(oidHex.dropFirst(2)))

        if FileManager.default.fileExists(atPath: objectPath) {
            // 对象已存在，直接返回 OID（git 的内容寻址保证相同内容 = 相同 OID）
            return oidHex
        }

        // 5. 用系统 zlib 压缩
        guard let compressedData = zlibCompress(objectData) else {
            throw GitError.operationFailed(
                "系统 zlib 压缩失败 (compress2 returned error)，无法创建 \(type) 对象。"
                + "这可能是一个底层 zlib 兼容性问题。"
            )
        }

        // 6. 创建目录并写入 loose object
        try FileManager.default.createDirectory(
            atPath: objectDir,
            withIntermediateDirectories: true
        )
        try compressedData.write(to: URL(fileURLWithPath: objectPath))

        return oidHex
    }

    /// 手动暂存单个文件 —— 绕过 libgit2 内部 zlib。
    ///
    /// 当 `git_index_add_bypath` 和 `git_index_add_all` 都因 "failed to
    /// initialize zlib" 失败时，此方法：
    /// 1. 读取文件内容
    /// 2. 手动创建 blob loose object（用系统 zlib 压缩）
    /// 3. 构造 `git_index_entry` 并调用 `git_index_add` 添加到 index
    ///
    /// `git_index_add` 不创建 blob（只添加条目），所以不触发 libgit2
    /// 内部的 deflate。后续 `git_index_write` 也不使用 zlib（index 文件
    /// 格式不压缩）。
    private func manualStageFile(repo: OpaquePointer, index: OpaquePointer, filePath: String) throws {
        // 1. 读取文件内容
        let fullPath = (repositoryPath as NSString).appendingPathComponent(filePath)
        guard let fileData = FileManager.default.contents(atPath: fullPath) else {
            throw GitError.stageFailed("无法读取文件内容: \(fullPath)")
        }

        // 2. 手动创建 blob 对象，获取 OID
        let blobOidHex = try writeLooseObject(type: "blob", content: fileData)

        // 3. 将 OID 字符串解析为 git_oid
        var oid = git_oid()
        let parseCode = blobOidHex.withCString { cstr -> Int32 in
            git_oid_fromstr(&oid, cstr)
        }
        if parseCode != 0 {
            throw GitError.stageFailed("无法解析 blob OID: \(blobOidHex)")
        }

        // 4. 构造 git_index_entry
        var entry = git_index_entry()
        entry.mode = 33188 // GIT_FILEMODE_BLOB = 0o100644
        entry.file_size = UInt32(fileData.count)
        entry.id = oid

        // 获取文件属性填充 ctime/mtime（最佳努力，失败用 0）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
            if let modDate = attrs[.modificationDate] as? Date {
                var mtime = git_time_t()
                mtime.seconds = Int64(modDate.timeIntervalSince1970)
                mtime.nanoseconds = 0
                entry.mtime = mtime
            }
            if let creationDate = attrs[.creationDate] as? Date {
                var ctime = git_time_t()
                ctime.seconds = Int64(creationDate.timeIntervalSince1970)
                ctime.nanoseconds = 0
                entry.ctime = ctime
            }
        }

        // dev/ino/uid/gid 设为 0（libgit2 在读取时会用 stat 重新填充）
        entry.dev = 0
        entry.ino = 0
        entry.uid = 0
        entry.gid = 0

        // path 需要是 C 字符串，在 git_index_add 执行期间保持有效
        let cPath = strdup(filePath)
        defer { free(cPath) }
        if let cp = cPath {
            entry.path = UnsafePointer(cp)
        }
        entry.flags = 0
        entry.flags_extended = 0

        // 5. 添加到 index
        //    git_index_add 不创建 blob（OID 已存在于 .git/objects/），
        //    也不使用 zlib，所以不会触发 "failed to initialize zlib"。
        let addCode = git_index_add(index, &entry)
        if addCode != 0 {
            let detail: String
            if let err = git_error_last(), let msg = err.pointee.message {
                detail = String(cString: msg)
            } else {
                detail = "unknown"
            }
            throw GitError.stageFailed(
                "手动暂存也失败: git_index_add 返回 \(addCode) (detail: \(detail))"
            )
        }
    }

    /// 手动暂存所有改动文件 —— 当 git_index_add_all 因 zlib 失败时的 fallback。
    ///
    /// 遍历 status list 中的未追踪文件和已修改文件，对每个文件调用
    /// manualStageFile 手动创建 blob 并添加到 index。
    private func manualStageAll(repo: OpaquePointer, index: OpaquePointer) throws {
        // 构建 status options（与 status() 方法一致）
        var opts = git_status_options()
        git_status_init_options(&opts, numericCast(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        let flagsRaw = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        withUnsafeMutablePointer(to: &opts.flags) { ptr in
            ptr.withMemoryRebound(to: type(of: flagsRaw).self, capacity: 1) { rawPtr in
                rawPtr.pointee = flagsRaw
            }
        }

        var statusList: OpaquePointer? = nil
        try checkGit(
            git_status_list_new(&statusList, repo, &opts),
            operation: "git_status_list_new (manualStageAll)"
        )
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)
        var stagedCount: Int = 0

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let flags = entry.pointee.status

            // 未追踪文件（WT_NEW）
            if flags.rawValue & GIT_STATUS_WT_NEW.rawValue != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: true)
                if !path.hasSuffix("/") {
                    try manualStageFile(repo: repo, index: index, filePath: path)
                    stagedCount += 1
                }
            }
            // 已修改文件（WT_MODIFIED）
            else if flags.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: false)
                try manualStageFile(repo: repo, index: index, filePath: path)
                stagedCount += 1
            }
            // 已删除文件（WT_DELETED）—— 从 index 中移除
            else if flags.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 {
                let path = extractPath(from: entry.pointee.index_to_workdir, isNew: false)
                _ = path.withCString { git_index_remove_bypath(index, $0) }
                stagedCount += 1
            }
        }

        if stagedCount == 0 {
            throw GitError.stageFailed("没有可暂存的文件改动")
        }
    }

    /// 手动创建提交 —— 绕过 libgit2 内部 zlib。
    ///
    /// 当 `git_index_write_tree` 或 `git_commit_create` 因 zlib 失败时，
    /// 此方法手动完成整个提交流程：
    /// 1. 读取 index 中所有条目
    /// 2. 构建 tree 对象内容并写入 loose object
    /// 3. 构建 commit 对象内容并写入 loose object
    /// 4. 更新 .git/refs/heads/<branch> 指向新 commit
    private func manualCommit(repo: OpaquePointer, index: OpaquePointer, message: String) throws {
        // 1. 读取 index 中所有条目
        let entryCount = git_index_entrycount(index)
        if entryCount == 0 {
            throw GitError.commitFailed("没有暂存的文件，无法提交")
        }

        // 2. 收集所有 index 条目
        struct TreeEntry {
            let name: String
            let mode: String
            let oid: git_oid
        }
        var treeEntries: [TreeEntry] = []

        for i in 0..<entryCount {
            guard let rawEntry = git_index_get_byindex(index, i) else { continue }
            let e = rawEntry.pointee

            // 获取路径
            let pathStr: String
            if let p = e.path {
                pathStr = String(cString: p)
            } else {
                continue
            }

            // 获取模式字符串
            let modeStr: String
            switch e.mode {
            case 0o100644: modeStr = "100644"  // 普通文件
            case 0o100755: modeStr = "100755"  // 可执行文件
            case 0o120000: modeStr = "120000"  // 符号链接
            case 0o160000: modeStr = "160000"  // gitlink (submodule)
            default: modeStr = "100644"
            }

            treeEntries.append(TreeEntry(name: pathStr, mode: modeStr, oid: e.id))
        }

        // 3. 按 git 规则排序 tree 条目（按名称排序，目录名追加 '/'）
        treeEntries.sort { a, b in
            // git 的 tree 排序：目录名追加 '/' 后比较
            // 对于 index 条目（都是文件），直接按名称排序即可
            a.name < b.name
        }

        // 4. 构建 tree 对象内容
        // 格式："<mode> <name>\0<20-byte binary OID>" 重复
        var treeContent = Data()
        for entry in treeEntries {
            let entryHeader = "\(entry.mode) \(entry.name)"
            treeContent.append(entryHeader.data(using: .isoLatin1) ?? Data())
            treeContent.append(0) // null 分隔符
            // 附加 20 字节二进制 OID
            var oidCopy = entry.oid
            withUnsafeBytes(of: &oidCopy) { rawBuf in
                treeContent.append(contentsOf: rawBuf)
            }
        }

        // 5. 写入 tree loose object
        let treeOidHex = try writeLooseObject(type: "tree", content: treeContent)

        // 6. 构建 commit 对象内容
        // 格式：
        //   tree <tree_oid_hex>\n
        //   parent <parent_oid_hex>\n  (可选，首次提交无 parent)
        //   author <name> <email> <timestamp> <timezone>\n
        //   committer <name> <email> <timestamp> <timezone>\n
        //   \n
        //   <commit message>\n
        let authorName = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? BaizeGit.defaultCommitAuthor
        let authorEmail = BaizeGit.defaultCommitEmail
        let timestamp = Int64(Date().timeIntervalSince1970)

        // 计算时区偏移（如 +0800）
        let tzOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
        let tzSign = tzOffsetMinutes >= 0 ? "+" : "-"
        let tzAbs = abs(tzOffsetMinutes)
        let tzStr = String(format: "%@%02d%02d", tzSign, tzAbs / 60, tzAbs % 60)

        var commitContent = ""
        commitContent += "tree \(treeOidHex)\n"

        // 检查是否有 parent commit（从 HEAD 解析）
        var headRef: OpaquePointer? = nil
        let headCode = git_repository_head(&headRef, repo)
        if headCode == 0, let hr = headRef {
            defer { git_reference_free(hr) }
            var peeledObj: OpaquePointer? = nil
            if git_reference_peel(&peeledObj, hr, GIT_OBJECT_COMMIT) == 0, let obj = peeledObj {
                defer { git_object_free(obj) }
                if let oidPtr = git_object_id(obj) {
                    var parentOid = oidPtr.pointee
                    let parentHex = withUnsafePointer(to: &parentOid) { ptr -> String in
                        guard let hex = git_oid_tostr_s(ptr) else { return "" }
                        return String(cString: hex)
                    }
                    if !parentHex.isEmpty {
                        commitContent += "parent \(parentHex)\n"
                    }
                }
            }
        }
        // headCode == -9 (unborn branch) 或 -3 (not found) → 首次提交，无 parent

        commitContent += "author \(authorName) <\(authorEmail)> \(timestamp) \(tzStr)\n"
        commitContent += "committer \(authorName) <\(authorEmail)> \(timestamp) \(tzStr)\n"
        commitContent += "\n"
        commitContent += message
        if !message.hasSuffix("\n") {
            commitContent += "\n"
        }

        // 7. 写入 commit loose object
        let commitOidHex = try writeLooseObject(
            type: "commit",
            content: commitContent.data(using: .utf8) ?? Data()
        )

        // 8. 更新 HEAD ref —— 写入 .git/refs/heads/<branch>
        let branchName = try getCurrentBranchName(repo: repo)
        let refPath = (repositoryPath as NSString)
            .appendingPathComponent(".git/refs/heads/\(branchName)")
        let refDir = (refPath as NSString).deletingLastPathComponent

        // 创建 refs/heads 目录（如果不存在）
        try FileManager.default.createDirectory(
            atPath: refDir,
            withIntermediateDirectories: true
        )

        // 写入 commit OID 到 ref 文件
        try "\(commitOidHex)\n".write(
            to: URL(fileURLWithPath: refPath),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Zlib Diagnostics

    /// 测试 zlib 是否正常工作 —— 用于诊断 "failed to initialize zlib" 问题。
    ///
    /// 测试两个维度：
    /// 1. libgit2 内部 zlib（通过 git_index 操作间接测试）
    /// 2. 系统 zlib（直接调用 compress2 测试）
    ///
    /// 返回 true 表示系统 zlib 可用（手动 loose object 创建可行）。
    /// 返回 false 表示系统 zlib 也不可用（底层兼容性问题）。
    func testZlib() async -> Bool {
        guard libgit2InitResult >= 0 else { return false }

        // 测试 1: 系统 zlib 直接压缩
        let testData = "zlib test \(Date().timeIntervalSince1970)".data(using: .utf8) ?? Data()
        let systemZlibOk = (zlibCompress(testData) != nil)

        // 测试 2: libgit2 index 读取（间接测试 zlib inflate）
        // 此测试不影响返回值，仅用于未来扩展诊断信息
        var libgit2IndexOk = false
        do {
            let repo = try openRepository()
            defer { git_repository_free(repo) }
            var index: OpaquePointer? = nil
            if git_repository_index(&index, repo) == 0, let idx = index {
                _ = git_index_entrycount(idx)
                git_index_free(idx)
                libgit2IndexOk = true
            }
        } catch {
            libgit2IndexOk = false
        }
        _ = libgit2IndexOk // 标记已使用（诊断信息，保留供未来扩展）

        // 系统 zlib 可用是手动 loose object 创建的前提
        return systemZlibOk
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

        // Bug fix (P0, round 7): index 预热 —— 读取 entry count 并写回，
        // 强制初始化 index 内部结构，可能修复 "failed to initialize zlib" 问题。
        warmupIndex(index)

        let code = normalizedPath.withCString { git_index_add_bypath(index, $0) }
        if code != 0 {
            // 捕获 libgit2 详细错误信息
            let detail: String
            if let err = git_error_last(), let msg = err.pointee.message {
                detail = String(cString: msg)
            } else {
                detail = "unknown"
            }

            // Fallback 1: 尝试 git_index_add_all（pathspec 匹配）
            let cPath = strdup(normalizedPath)
            var pathStrings: [UnsafeMutablePointer<CChar>?] = [cPath]
            var pathspec = git_strarray(strings: &pathStrings, count: 1)
            let fallbackCode = git_index_add_all(index, &pathspec, 0, nil, nil)
            if let p = cPath { free(p) }

            if fallbackCode != 0 {
                let fallbackDetail: String
                if let err = git_error_last(), let msg = err.pointee.message {
                    fallbackDetail = String(cString: msg)
                } else {
                    fallbackDetail = "unknown"
                }

                // Bug fix (P0, round 7): Fallback 2 —— 手动创建 blob 对象。
                // 当 libgit2 内部 zlib 初始化失败 ("failed to initialize zlib") 时，
                // add_bypath 和 add_all 都会失败（它们内部创建 blob 需要 deflate）。
                // 此时用系统 zlib (libz.tbd) 手动创建 loose object，再用
                // git_index_add 添加条目（不触发 deflate）。
                do {
                    try manualStageFile(repo: repo, index: index, filePath: normalizedPath)
                } catch {
                    // 手动暂存也失败了 —— 给用户最清晰的错误信息
                    throw GitError.stageFailed(
                        "暂存失败: libgit2 add_bypath (code: \(code), detail: \(detail)); "
                        + "add_all fallback (code: \(fallbackCode), detail: \(fallbackDetail)); "
                        + "手动暂存也失败: \(error.localizedDescription)"
                    )
                }
                // 手动暂存成功，继续执行 git_index_write
            }
        }
        try checkGit(git_index_write(index), operation: "git_index_write")
    }

    func stageAll() async throws {
        let repo = try openRepository()
        defer { git_repository_free(repo) }
        var index: OpaquePointer? = nil
        try checkGit(git_repository_index(&index, repo), operation: "git_repository_index")
        defer { git_index_free(index) }

        // Bug fix (P0, round 7): index 预热
        warmupIndex(index)

        var pathspec = git_strarray(strings: nil, count: 0)
        let code = git_index_add_all(index, &pathspec, 0, nil, nil)
        if code != 0 {
            // Bug fix (P0, round 7): add_all 失败时尝试手动暂存所有文件
            let detail: String
            if let err = git_error_last(), let msg = err.pointee.message {
                detail = String(cString: msg)
            } else {
                detail = "unknown"
            }

            do {
                try manualStageAll(repo: repo, index: index)
            } catch {
                throw GitError.stageFailed(
                    "git_index_add_all failed (code: \(code), detail: \(detail)); "
                    + "手动暂存所有文件也失败: \(error.localizedDescription)"
                )
            }
        }
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
                    // Bug fix (P0, round 7): index 预热
                    warmupIndex(idx)
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
            // Bug fix (P0, round 7): index 预热
            warmupIndex(index)
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
            // Bug fix (P0, round 7): index 预热
            warmupIndex(index)
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

        // Bug fix (P0, round 7): 尝试正常提交路径（git_index_write_tree + git_commit_create）。
        // 如果因 zlib 失败（"failed to initialize zlib"），回退到手动创建
        // tree + commit loose objects + 更新 HEAD ref。
        var treeOid = git_oid()
        let writeTreeCode = git_index_write_tree(&treeOid, index)

        if writeTreeCode != 0 {
            // git_index_write_tree 失败 —— 可能是 zlib 问题
            let treeDetail: String
            if let err = git_error_last(), let msg = err.pointee.message {
                treeDetail = String(cString: msg)
            } else {
                treeDetail = "unknown"
            }

            // 回退到手动提交
            do {
                try manualCommit(repo: repo, index: index, message: message)
                return // 手动提交成功，直接返回
            } catch {
                throw GitError.commitFailed(
                    "git_index_write_tree 失败 (code: \(writeTreeCode), detail: \(treeDetail)); "
                    + "手动提交也失败: \(error.localizedDescription)"
                )
            }
        }

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
            if createCode != 0 {
                // git_commit_create 失败 —— 可能是 zlib 问题
                let commitDetail: String
                if let err = git_error_last(), let msg = err.pointee.message {
                    commitDetail = String(cString: msg)
                } else {
                    commitDetail = "unknown"
                }
                // 回退到手动提交
                do {
                    try manualCommit(repo: repo, index: index, message: message)
                } catch {
                    throw GitError.commitFailed(
                        "git_commit_create 失败 (code: \(createCode), detail: \(commitDetail)); "
                        + "手动提交也失败: \(error.localizedDescription)"
                    )
                }
            }
        } catch GitError.emptyRepository {
            var commitOid = git_oid()
            let createCode = message.withCString { msgPtr in
                git_commit_create(&commitOid, repo, "HEAD", signature, signature, nil, msgPtr, tree, 0, nil)
            }
            if createCode != 0 {
                // git_commit_create 失败 —— 可能是 zlib 问题
                let commitDetail: String
                if let err = git_error_last(), let msg = err.pointee.message {
                    commitDetail = String(cString: msg)
                } else {
                    commitDetail = "unknown"
                }
                // 回退到手动提交（首次提交）
                do {
                    try manualCommit(repo: repo, index: index, message: message)
                } catch {
                    throw GitError.commitFailed(
                        "git_commit_create (initial) 失败 (code: \(createCode), detail: \(commitDetail)); "
                        + "手动提交也失败: \(error.localizedDescription)"
                    )
                }
            }
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

    func push() async throws {
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
}
