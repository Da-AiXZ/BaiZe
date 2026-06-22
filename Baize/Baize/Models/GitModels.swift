import Foundation
import SwiftUI

// MARK: - Git Error

/// Git 操作统一错误类型 — 独立于 BaizeError，职责分离
/// 定义在 GitModels.swift，遵循 LocalizedError 协议
enum GitError: LocalizedError {
    /// 仓库路径不存在
    case repositoryNotFound(String)
    /// 指定路径不是 Git 仓库
    case notAGitRepository
    /// libgit2 C API 返回错误码
    case libgit2Error(code: Int32, message: String)
    /// 凭据未配置（push 时无 token）
    case credentialsMissing
    /// 凭据无效（token 过期或错误）
    case credentialsInvalid
    /// push 操作失败
    case pushFailed(String)
    /// commit 操作失败
    case commitFailed(String)
    /// stage/unstage 操作失败
    case stageFailed(String)
    /// diff 操作失败
    case diffFailed(String)
    /// 分支不存在
    case branchNotFound(String)
    /// 工作区有未提交改动（切换分支时）
    case dirtyWorkingTree
    /// 网络错误（push/fetch 连接失败）
    case networkError(String)
    /// 仓库为空（无 HEAD）
    case emptyRepository
    /// 通用操作失败
    case operationFailed(String)
    /// 合并冲突（冲突文件列表）
    case mergeConflict([String])
    /// Rebase 冲突（冲突文件列表）
    case rebaseConflict([String])
    /// Clone 操作失败
    case cloneFailed(String)
    /// 目录已存在（clone 时目标目录非空）
    case directoryExists(String)
    /// 贮藏列表为空
    case stashEmpty
    /// 标签已存在
    case tagExists(String)
    /// 不能删除当前所在分支
    case cannotDeleteCurrentBranch

    var errorDescription: String? {
        switch self {
        case .repositoryNotFound(let path):
            return "仓库路径不存在: \(path)"
        case .notAGitRepository:
            return "当前目录不是 Git 仓库"
        case .libgit2Error(let code, let message):
            return "Git 错误 (code: \(code)): \(message)"
        case .credentialsMissing:
            return "Git 凭据未配置，请在设置中添加 GitHub Token"
        case .credentialsInvalid:
            return "Git 凭据无效，请检查 Token 是否正确"
        case .pushFailed(let reason):
            return "推送失败: \(reason)"
        case .commitFailed(let reason):
            return "提交失败: \(reason)"
        case .stageFailed(let reason):
            return "暂存失败: \(reason)"
        case .diffFailed(let reason):
            return "Diff 查看失败: \(reason)"
        case .branchNotFound(let name):
            return "分支不存在: \(name)"
        case .dirtyWorkingTree:
            return "工作区有未提交改动，请先提交或暂存"
        case .networkError(let reason):
            return "网络错误: \(reason)"
        case .emptyRepository:
            return "仓库为空（无任何提交）"
        case .operationFailed(let reason):
            return "操作失败: \(reason)"
        case .mergeConflict(let files):
            return "合并冲突，涉及 \(files.count) 个文件: \(files.joined(separator: ", "))"
        case .rebaseConflict(let files):
            return "Rebase 冲突，涉及 \(files.count) 个文件: \(files.joined(separator: ", "))"
        case .cloneFailed(let reason):
            return "Clone 失败: \(reason)"
        case .directoryExists(let path):
            return "目录已存在: \(path)"
        case .stashEmpty:
            return "贮藏列表为空"
        case .tagExists(let name):
            return "标签已存在: \(name)"
        case .cannotDeleteCurrentBranch:
            return "不能删除当前所在分支，请先切换到其他分支"
        }
    }
}

// MARK: - Git Diff Types

/// Diff 查看类型 — 控制对比的两个版本
enum GitDiffType: String, CaseIterable, Hashable {
    /// 工作区 vs 暂存区（未暂存的改动）
    case workingTreeVsIndex
    /// 暂存区 vs HEAD（已暂存的改动）
    case indexVsHead

    /// UI 显示名称
    var displayName: String {
        switch self {
        case .workingTreeVsIndex:
            return "工作区 vs 暂存区"
        case .indexVsHead:
            return "暂存区 vs HEAD"
        }
    }
}

/// Diff 行类型
enum GitDiffLineType: String, CaseIterable {
    /// 上下文行（无变化）
    case context
    /// 新增行
    case addition
    /// 删除行
    case deletion

    /// 行前缀符号
    var prefix: String {
        switch self {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        }
    }

    /// 行颜色（DeepSeek 蓝白配色）
    var color: Color {
        switch self {
        case .context: return .baizeTextSecondary
        case .addition: return .baizeSuccess
        case .deletion: return .baizeError
        }
    }
}

/// Diff 单行
struct GitDiffLine: Identifiable, Hashable {
    let id = UUID()
    /// 行类型
    let type: GitDiffLineType
    /// 行内容（不含前缀符号）
    let content: String
    /// 旧文件行号（删除行/上下文行有值）
    let oldLineNumber: Int?
    /// 新文件行号（新增行/上下文行有值）
    let newLineNumber: Int?
}

/// Diff Hunk（一个 @@ ... @@ 块）
struct GitDiffHunk: Identifiable, Hashable {
    let id = UUID()
    /// 旧文件起始行号
    let oldStart: Int
    /// 旧文件行数
    let oldLines: Int
    /// 新文件起始行号
    let newStart: Int
    /// 新文件行数
    let newLines: Int
    /// Hunk 内的行列表
    var lines: [GitDiffLine]
}

/// Diff 结果（单个文件）
struct GitDiffResult: Identifiable, Hashable {
    let id = UUID()
    /// 文件路径
    let filePath: String
    /// Diff 类型
    let diffType: GitDiffType
    /// Hunk 列表
    var hunks: [GitDiffHunk]
    /// 原始 patch 文本（完整 diff 输出）
    let rawPatch: String
}

// MARK: - Git Status Types

/// 文件变更状态
enum GitFileChangeStatus: String, CaseIterable {
    case modified
    case added
    case deleted
    case renamed
    case untracked

    /// 状态图标（SF Symbol 或文本符号）
    var icon: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "??"
        }
    }

    /// 状态颜色（DeepSeek 蓝白配色）
    var color: Color {
        switch self {
        case .modified: return .baizeWarning
        case .added: return .baizeSuccess
        case .deleted: return .baizeError
        case .renamed: return .baizeAccent
        case .untracked: return .baizeTextSecondary
        }
    }

    /// 状态中文描述
    var displayName: String {
        switch self {
        case .modified: return "已修改"
        case .added: return "已新增"
        case .deleted: return "已删除"
        case .renamed: return "已重命名"
        case .untracked: return "未追踪"
        }
    }
}

/// 单个文件的 Git 状态
struct GitFileStatus: Identifiable, Hashable {
    let id = UUID()
    /// 文件路径（相对仓库根目录）
    let path: String
    /// 显示名称（文件名）
    var displayName: String {
        (path as NSString).lastPathComponent
    }
    /// 变更状态
    let changeStatus: GitFileChangeStatus
    /// 是否已暂存
    let isStaged: Bool
}

/// 仓库整体状态
struct GitStatus: Hashable {
    /// 未暂存的改动文件列表（Modified — 工作区 vs 暂存区）
    var modified: [GitFileStatus]
    /// 已暂存的改动文件列表（Staged — 暂存区 vs HEAD）
    var staged: [GitFileStatus]
    /// 未追踪文件列表（Untracked — 新文件）
    var untracked: [GitFileStatus]
    /// 当前分支名
    var currentBranch: String

    /// 是否有任何改动
    var hasChanges: Bool {
        !modified.isEmpty || !staged.isEmpty || !untracked.isEmpty
    }

    /// 是否有已暂存的改动（commit 按钮启用条件）
    var hasStagedChanges: Bool {
        !staged.isEmpty
    }
}

// MARK: - Git Commit

/// 单条提交记录
struct GitCommit: Identifiable, Hashable {
    let id = UUID()
    /// 完整 OID（40 字符 SHA-1）
    let oid: String
    /// 短 OID（前 7 字符）
    var shortOid: String {
        String(oid.prefix(7))
    }
    /// 作者名
    let author: String
    /// 作者邮箱
    let email: String
    /// 提交时间
    let date: Date
    /// 完整提交消息
    let message: String
    /// 提交消息首行
    var messageHeadline: String {
        message.split(separator: "\n").first.map(String.init) ?? message
    }
}

// MARK: - Git Branch

/// 分支信息
struct GitBranch: Identifiable, Hashable {
    let id = UUID()
    /// 分支名
    let name: String
    /// 是否为当前分支
    let isCurrent: Bool
    /// 是否为远程分支
    let isRemote: Bool
}

// MARK: - Git Sub Tab

/// Git Tab 底部子 Tab 枚举
enum GitSubTab: String, CaseIterable, Hashable {
    /// 改动（status + commit）
    case changes
    /// 历史（log）
    case history
    /// 分支（branch）
    case branches
    /// 贮藏（stash）
    case stash

    /// 子 Tab 标题
    var title: String {
        switch self {
        case .changes: return "改动"
        case .history: return "历史"
        case .branches: return "分支"
        case .stash: return "贮藏"
        }
    }

    /// 子 Tab 图标
    var systemImage: String {
        switch self {
        case .changes: return "doc.text"
        case .history: return "clock.arrow.circlepath"
        case .branches: return "arrow.triangle.branch"
        case .stash: return "tray.fill"
        }
    }
}

// MARK: - Git Stash

/// Git 贮藏条目
struct GitStashEntry: Identifiable {
    let id = UUID()
    /// 贮藏索引（stash@{0}, stash@{1}, ...）
    let index: Int
    /// 贮藏消息
    let message: String
    /// 贮藏时间
    let date: Date
}

// MARK: - Git Tag

/// Git 标签
struct GitTag: Identifiable {
    let id = UUID()
    /// 标签名
    let name: String
    /// 标签 OID（SHA-1）
    let oid: String
    /// 标签创建时间
    let date: Date
    /// 标签消息（附注标签有值，轻量标签为 nil）
    let message: String?
    /// 是否为附注标签
    let isAnnotated: Bool
}

// MARK: - Git Fetch Result

/// Git Fetch 操作结果
struct GitFetchResult {
    /// 更新的分支数
    let updatedBranches: Int
    /// 接收的字节数
    let receivedBytes: Int
}

// MARK: - Git Merge Result

/// Git Merge 操作结果
struct GitMergeResult {
    /// 是否成功（无冲突）
    let success: Bool
    /// 冲突文件列表（成功时为空）
    let conflictFiles: [String]
    /// 是否为快进合并
    let isFastForward: Bool
}

// MARK: - Git Reset Mode

/// Git Reset 模式
enum GitResetMode: String, CaseIterable {
    /// soft：仅移动 HEAD，暂存区和工作区不变
    case soft
    /// mixed：移动 HEAD + 重置暂存区，工作区不变（默认模式）
    case mixed
    /// hard：移动 HEAD + 重置暂存区 + 重置工作区（危险）
    case hard

    /// 显示名称
    var displayName: String {
        switch self {
        case .soft: return "Soft（保留暂存区）"
        case .mixed: return "Mixed（重置暂存区）"
        case .hard: return "Hard（重置所有改动）"
        }
    }
}

// MARK: - Git Remote Info (B10)

/// Git 远程仓库信息 — git remote -v 输出
struct GitRemoteInfo: Identifiable, Hashable {
    let id = UUID()
    /// 远程名称（如 origin）
    let name: String
    /// 远程 URL（fetch/push 共用）
    let url: String
    /// URL 类型（fetch/push）
    let type: String
}

// MARK: - Git Show Result (B15)

/// Git Show 结果 — git show <commit> 输出
struct GitShowResult: Hashable {
    /// commit OID
    let oid: String
    /// 作者名
    let author: String
    /// 作者邮箱
    let email: String
    /// 提交时间
    let date: Date
    /// 提交消息
    let message: String
    /// diff patch 文本
    let patch: String
}
