import Foundation

/// Swift 原生命令实现 — 不依赖 ios_system
///
/// 作为 ios_system 的双保险 fallback，确保高频命令在 ios_system 不可用或行为异常时仍能正常工作。
/// 每个命令返回 `RuntimeExecutor.ExecutionResult?`，nil 表示不是原生命令（继续走 ios_popen）。
///
/// 支持的命令：ls, cat, pwd, wc, stat, touch, mkdir, rm, cp, mv, head, tail, find
///
/// 设计原则：
/// - 纯 Swift 实现，不调用 ios_popen / ios_system
/// - 线程安全：所有方法为 static，使用 FileManager（线程安全），无共享可变状态
/// - 输出格式模仿 BSD Unix 命令（ls -l 等）
/// - 完善的错误处理（文件不存在、权限错误、参数错误）
struct NativeCommands {

    // MARK: - Supported Commands

    /// 支持的原生命令名称集合
    private static let supportedCommands: Set<String> = [
        "ls", "cat", "pwd", "wc", "stat", "touch",
        "mkdir", "rm", "cp", "mv", "head", "tail", "find",
    ]

    // MARK: - Public Entry Point

    /// 执行原生命令
    ///
    /// 调用顺序：RuntimeExecutor.executeCommand() → handleBuiltinCommand → **NativeCommands** → ios_popen
    /// 含 shell 操作符（|, >, <, &&, ||, ;）的命令不走原生路径，返回 nil 由 ios_system parser 处理。
    ///
    /// - Parameters:
    ///   - command: 完整命令字符串（如 "ls -la", "cat file.txt", "wc -l file.swift"）
    ///   - workingDir: 工作目录（绝对路径）
    /// - Returns: 执行结果；nil 表示不是原生命令，继续走 ios_popen
    static func execute(command: String, workingDir: String) -> RuntimeExecutor.ExecutionResult? {
        // 含 shell 操作符的命令不走原生路径（需要 ios_system parser 解析管道/重定向）
        if containsShellOperators(command) {
            return nil
        }

        let tokens = tokenize(command)
        guard let cmdName = tokens.first?.lowercased() else {
            return nil
        }

        guard supportedCommands.contains(cmdName) else {
            return nil
        }

        let args = Array(tokens.dropFirst())

        switch cmdName {
        case "ls":
            return ls(args: args, workingDir: workingDir)
        case "cat":
            return cat(args: args, workingDir: workingDir)
        case "pwd":
            return pwd(workingDir: workingDir)
        case "wc":
            return wc(args: args, workingDir: workingDir)
        case "stat":
            return stat(args: args, workingDir: workingDir)
        case "touch":
            return touch(args: args, workingDir: workingDir)
        case "mkdir":
            return mkdir(args: args, workingDir: workingDir)
        case "rm":
            return rm(args: args, workingDir: workingDir)
        case "cp":
            return cp(args: args, workingDir: workingDir)
        case "mv":
            return mv(args: args, workingDir: workingDir)
        case "head":
            return head(args: args, workingDir: workingDir)
        case "tail":
            return tail(args: args, workingDir: workingDir)
        case "find":
            return find(args: args, workingDir: workingDir)
        default:
            return nil
        }
    }

    // MARK: - ls

    /// ls 命令 — 列出目录内容
    ///
    /// 支持的 flags:
    /// - `-l`: 长格式（权限/链接数/owner/size/date/name）
    /// - `-a`: 显示隐藏文件（以 . 开头的文件）
    /// - `-la`, `-al`: 组合
    /// - `-1`: 每行一个文件名（无 -l 时的默认行为）
    ///
    /// 参数：可选路径（默认为 workingDir），支持多个路径
    private static func ls(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var showLong = false
        var showAll = false
        var paths: [String] = []

        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                // 解析 flags：-l, -a, -la, -al, -1 等
                let flagChars = arg.dropFirst()
                for ch in flagChars {
                    switch ch {
                    case "l": showLong = true
                    case "a": showAll = true
                    case "1": showLong = false  // -1 显式指定单列，与无 -l 相同
                    case "h", "r", "t", "S", "G", "F":
                        // 忽略其他常见 flags（不报错，静默忽略）
                        break
                    default:
                        // 未知 flag，忽略
                        break
                    }
                }
            } else {
                paths.append(arg)
            }
        }

        // 默认路径为 workingDir
        if paths.isEmpty {
            paths = [workingDir]
        }

        let fm = FileManager.default
        var stdout = ""
        var stderr = ""

        for (index, rawPath) in paths.enumerated() {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            // 检查路径是否存在
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: resolvedPath, isDirectory: &isDir) {
                stderr += "ls: \(rawPath): No such file or directory\n"
                continue
            }

            // 多路径时显示路径头
            if paths.count > 1 {
                if index > 0 { stdout += "\n" }
                stdout += "\(resolvedPath):\n"
            }

            if isDir.boolValue {
                // 列出目录内容
                do {
                    let entries = try fm.contentsOfDirectory(atPath: resolvedPath)
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

                    // 过滤隐藏文件（除非 -a）
                    let filteredEntries = showAll ? entries : entries.filter { !$0.hasPrefix(".") }

                    if showLong {
                        stdout += formatLsLong(entries: filteredEntries, dirPath: resolvedPath)
                    } else {
                        for entry in filteredEntries {
                            stdout += entry + "\n"
                        }
                    }
                } catch {
                    stderr += "ls: \(rawPath): \(error.localizedDescription)\n"
                }
            } else {
                // 单个文件，显示文件信息
                if showLong {
                    stdout += formatLsLongEntry(name: rawPath, fullPath: resolvedPath, displayName: (resolvedPath as NSString).lastPathComponent)
                } else {
                    stdout += rawPath + "\n"
                }
            }
        }

        let hasError = !stderr.isEmpty
        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    /// 格式化 ls -l 长格式输出
    private static func formatLsLong(entries: [String], dirPath: String) -> String {
        let fm = FileManager.default
        var output = ""
        var totalBlocks: Int = 0

        // 先收集所有条目信息
        struct EntryInfo {
            let name: String
            let permission: String
            let linkCount: Int
            let size: Int64
            let modificationDate: Date
            let isDirectory: Bool
            let isSymlink: Bool
            let symlinkTarget: String?
        }

        var infos: [EntryInfo] = []

        for entry in entries {
            let fullPath = (dirPath as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else {
                continue
            }

            let fileType = (attrs[.type] as? FileAttributeType) ?? .typeRegular
            let isDirectory = (fileType == .typeDirectory)
            let isSymlink = (fileType == .typeSymbolicLink)

            let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()

            // 链接数：目录 = 2 + 子目录数，文件 = 1
            var linkCount = 1
            if isDirectory {
                let subEntries = (try? fm.contentsOfDirectory(atPath: fullPath)) ?? []
                let subDirCount = subEntries.filter { entry in
                    let subPath = (fullPath as NSString).appendingPathComponent(entry)
                    var subIsDir: ObjCBool = false
                    return fm.fileExists(atPath: subPath, isDirectory: &subIsDir) && subIsDir.boolValue
                }.count
                linkCount = 2 + subDirCount
            }

            // 权限字符串
            let permStr = permissionString(permissions: permissions, isDirectory: isDirectory, isSymlink: isSymlink)

            // 符号链接目标
            var symlinkTarget: String? = nil
            if isSymlink {
                symlinkTarget = try? fm.destinationOfSymbolicLink(atPath: fullPath)
            }

            // 磁盘块数（512 字节为一块）
            totalBlocks += Int(ceil(Double(size) / 512.0))

            infos.append(EntryInfo(
                name: entry,
                permission: permStr,
                linkCount: linkCount,
                size: size,
                modificationDate: modDate,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                symlinkTarget: symlinkTarget
            ))
        }

        // 输出 total 行
        output += "total \(totalBlocks)\n"

        // 输出每个条目
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd HH:mm"

        for info in infos {
            // 权限位 + @ (扩展属性标记，iOS 文件通常有)
            output += info.permission + "@"
            // 链接数（右对齐，宽度 3）
            output += String(format: " %3d", info.linkCount)
            // owner 和 group
            output += " mobile  staff"
            // size（右对齐，宽度 8）
            output += String(format: " %8lld", info.size)
            // date
            output += " " + dateFormatter.string(from: info.modificationDate)
            // name
            output += " " + info.name
            // 符号链接目标
            if let target = info.symlinkTarget {
                output += " -> " + target
            }
            output += "\n"
        }

        return output
    }

    /// 格式化单个文件的 ls -l 输出（当 ls -l 指向单个文件时）
    private static func formatLsLongEntry(name: String, fullPath: String, displayName: String) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else {
            return "ls: \(name): No such file or directory\n"
        }

        let fileType = (attrs[.type] as? FileAttributeType) ?? .typeRegular
        let isDirectory = (fileType == .typeDirectory)
        let isSymlink = (fileType == .typeSymbolicLink)

        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        let permStr = permissionString(permissions: permissions, isDirectory: isDirectory, isSymlink: isSymlink)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd HH:mm"

        var output = permStr + "@"
        output += String(format: " %3d", 1)
        output += " mobile  staff"
        output += String(format: " %8lld", size)
        output += " " + dateFormatter.string(from: modDate)
        output += " " + displayName

        if isSymlink {
            if let target = try? fm.destinationOfSymbolicLink(atPath: fullPath) {
                output += " -> " + target
            }
        }
        output += "\n"

        return output
    }

    /// 生成权限字符串（如 "drwxr-xr-x"）
    private static func permissionString(permissions: UInt16, isDirectory: Bool, isSymlink: Bool) -> String {
        var perm = ""
        // 文件类型
        if isSymlink {
            perm += "l"
        } else if isDirectory {
            perm += "d"
        } else {
            perm += "-"
        }

        // Owner (rwx)
        perm += (permissions & 0o400 != 0) ? "r" : "-"
        perm += (permissions & 0o200 != 0) ? "w" : "-"
        perm += (permissions & 0o100 != 0) ? "x" : "-"

        // Group (rwx)
        perm += (permissions & 0o040 != 0) ? "r" : "-"
        perm += (permissions & 0o020 != 0) ? "w" : "-"
        perm += (permissions & 0o010 != 0) ? "x" : "-"

        // Other (rwx)
        perm += (permissions & 0o004 != 0) ? "r" : "-"
        perm += (permissions & 0o002 != 0) ? "w" : "-"
        perm += (permissions & 0o001 != 0) ? "x" : "-"

        return perm
    }

    // MARK: - cat

    /// cat 命令 — 输出文件内容
    ///
    /// 支持多个文件，按顺序拼接输出
    private static func cat(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        // 过滤 flags（cat -n 支持行号，但暂不实现）
        let filePaths = args.filter { !$0.hasPrefix("-") || $0 == "-" }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "cat: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stdout = ""
        var stderr = ""
        var hasError = false

        for rawPath in filePaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if !FileManager.default.fileExists(atPath: resolvedPath) {
                stderr += "cat: \(rawPath): No such file or directory\n"
                hasError = true
                continue
            }

            if let data = FileManager.default.contents(atPath: resolvedPath) {
                if let content = String(data: data, encoding: .utf8) {
                    stdout += content
                    // 确保以换行结尾
                    if !content.hasSuffix("\n") && rawPath != filePaths.last {
                        stdout += "\n"
                    }
                } else {
                    // 非 UTF-8 文件，输出字节数
                    stderr += "cat: \(rawPath): Is a binary file (\(data.count) bytes)\n"
                    hasError = true
                }
            } else {
                stderr += "cat: \(rawPath): Permission denied\n"
                hasError = true
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - pwd

    /// pwd 命令 — 输出当前工作目录
    private static func pwd(workingDir: String) -> RuntimeExecutor.ExecutionResult {
        return RuntimeExecutor.ExecutionResult(
            stdout: workingDir + "\n",
            stderr: "",
            exitCode: 0,
            isError: false
        )
    }

    // MARK: - wc

    /// wc 命令 — 统计行数/单词数/字节数
    ///
    /// 支持的 flags: -l (行数), -w (单词数), -c (字节数)
    /// 无 flags 时输出全部三项
    private static func wc(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var countLines = false
        var countWords = false
        var countBytes = false
        var filePaths: [String] = []

        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "l": countLines = true
                    case "w": countWords = true
                    case "c": countBytes = true
                    default: break
                    }
                }
            } else {
                filePaths.append(arg)
            }
        }

        // 无 flag 时默认全部统计
        if !countLines && !countWords && !countBytes {
            countLines = true
            countWords = true
            countBytes = true
        }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "wc: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stdout = ""
        var stderr = ""
        var hasError = false
        var totalLines = 0
        var totalWords = 0
        var totalBytes = 0

        for rawPath in filePaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if !FileManager.default.fileExists(atPath: resolvedPath) {
                stderr += "wc: \(rawPath): No such file or directory\n"
                hasError = true
                continue
            }

            guard let data = FileManager.default.contents(atPath: resolvedPath),
                  let content = String(data: data, encoding: .utf8) else {
                stderr += "wc: \(rawPath): Permission denied\n"
                hasError = true
                continue
            }

            // wc -l counts newline characters (not line segments)
            // "hello\nworld\n" → 2 newlines → wc -l returns 2
            // "hello\nworld" → 1 newline → wc -l returns 1
            // "" → 0 newlines → wc -l returns 0
            let lines = content.components(separatedBy: "\n").count - 1
            let words = content.split(whereSeparator: { $0.isWhitespace }).count
            let bytes = data.count

            totalLines += lines
            totalWords += words
            totalBytes += bytes

            var parts: [String] = []
            if countLines { parts.append(String(format: "%8d", lines)) }
            if countWords { parts.append(String(format: "%8d", words)) }
            if countBytes { parts.append(String(format: "%8d", bytes)) }
            stdout += parts.joined(separator: " ") + " \(rawPath)\n"
        }

        // 多文件时输出总计
        if filePaths.count > 1 {
            var parts: [String] = []
            if countLines { parts.append(String(format: "%8d", totalLines)) }
            if countWords { parts.append(String(format: "%8d", totalWords)) }
            if countBytes { parts.append(String(format: "%8d", totalBytes)) }
            stdout += parts.joined(separator: " ") + " total\n"
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - stat

    /// stat 命令 — 显示文件信息
    private static func stat(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        let filePaths = args.filter { !$0.hasPrefix("-") || $0 == "-" }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "stat: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stdout = ""
        var stderr = ""
        var hasError = false
        let fm = FileManager.default

        for rawPath in filePaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            guard let attrs = try? fm.attributesOfItem(atPath: resolvedPath) else {
                stderr += "stat: \(rawPath): No such file or directory\n"
                hasError = true
                continue
            }

            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()
            let creationDate = (attrs[.creationDate] as? Date) ?? Date()
            let fileType = (attrs[.type] as? FileAttributeType) ?? .typeRegular
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0

            let isDirectory = (fileType == .typeDirectory)
            let isSymlink = (fileType == .typeSymbolicLink)

            let typeStr: String
            if isSymlink { typeStr = "symbolic link" }
            else if isDirectory { typeStr = "directory" }
            else { typeStr = "regular file" }

            let permStr = permissionString(permissions: permissions, isDirectory: isDirectory, isSymlink: isSymlink)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            dateFormatter.timeZone = TimeZone.current

            stdout += "  File: \(rawPath)\n"
            stdout += "  Size: \(size)\t\tBlocks: \(Int(ceil(Double(size) / 512.0)))\tIO Block: 4096\t\(typeStr)\n"
            stdout += "Device: \(device)\tInode: \(inode)\tLinks: 1\n"
            stdout += "Access: (\(String(format: "%04o", permissions))/\(permStr))  Uid: (mobile)   Gid: (staff)\n"
            stdout += "Access: \(dateFormatter.string(from: modDate))\n"
            stdout += "Modify: \(dateFormatter.string(from: modDate))\n"
            stdout += "Change: \(dateFormatter.string(from: modDate))\n"
            stdout += " Birth: \(dateFormatter.string(from: creationDate))\n"

            if isSymlink {
                if let target = try? fm.destinationOfSymbolicLink(atPath: resolvedPath) {
                    stdout += "  Link: \(rawPath) -> \(target)\n"
                }
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - touch

    /// touch 命令 — 创建空文件或更新文件时间戳
    private static func touch(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        let filePaths = args.filter { !$0.hasPrefix("-") || $0 == "-" }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "touch: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stderr = ""
        var hasError = false
        let fm = FileManager.default

        for rawPath in filePaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if fm.fileExists(atPath: resolvedPath) {
                // 更新时间戳
                do {
                    try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: resolvedPath)
                } catch {
                    stderr += "touch: \(rawPath): \(error.localizedDescription)\n"
                    hasError = true
                }
            } else {
                // 创建空文件
                let parentDir = (resolvedPath as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parentDir) {
                    stderr += "touch: \(rawPath): No such file or directory\n"
                    hasError = true
                    continue
                }
                if !fm.createFile(atPath: resolvedPath, contents: nil) {
                    stderr += "touch: \(rawPath): Permission denied\n"
                    hasError = true
                }
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - mkdir

    /// mkdir 命令 — 创建目录
    ///
    /// 支持 -p 递归创建
    private static func mkdir(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var createParents = false
        var dirPaths: [String] = []

        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                for ch in arg.dropFirst() {
                    if ch == "p" { createParents = true }
                }
            } else {
                dirPaths.append(arg)
            }
        }

        if dirPaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "mkdir: missing operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stderr = ""
        var hasError = false
        let fm = FileManager.default

        for rawPath in dirPaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if fm.fileExists(atPath: resolvedPath) {
                if createParents {
                    continue  // -p 模式下已存在不报错
                }
                stderr += "mkdir: \(rawPath): File exists\n"
                hasError = true
                continue
            }

            do {
                if createParents {
                    try fm.createDirectory(atPath: resolvedPath, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(atPath: resolvedPath, withIntermediateDirectories: false)
                }
            } catch {
                stderr += "mkdir: \(rawPath): \(error.localizedDescription)\n"
                hasError = true
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - rm

    /// rm 命令 — 删除文件或目录
    ///
    /// 支持 -r (递归), -f (强制/忽略不存在), -rf (组合)
    /// 注意：危险命令，PermissionEngine 会在调用前确认
    private static func rm(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var recursive = false
        var force = false
        var filePaths: [String] = []

        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "r", "R": recursive = true
                    case "f": force = true
                    default: break
                    }
                }
            } else {
                filePaths.append(arg)
            }
        }

        if filePaths.isEmpty {
            if force {
                return RuntimeExecutor.ExecutionResult(stdout: "", stderr: "", exitCode: 0, isError: false)
            }
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "rm: missing operand\n",
                exitCode: 1,
                isError: true
            )
        }

        var stderr = ""
        var hasError = false
        let fm = FileManager.default

        for rawPath in filePaths {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if !fm.fileExists(atPath: resolvedPath) {
                if !force {
                    stderr += "rm: \(rawPath): No such file or directory\n"
                    hasError = true
                }
                continue
            }

            // 检查是否是目录
            var isDir: ObjCBool = false
            fm.fileExists(atPath: resolvedPath, isDirectory: &isDir)

            if isDir.boolValue && !recursive {
                stderr += "rm: \(rawPath): is a directory\n"
                hasError = true
                continue
            }

            do {
                try fm.removeItem(atPath: resolvedPath)
            } catch {
                stderr += "rm: \(rawPath): \(error.localizedDescription)\n"
                hasError = true
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - cp

    /// cp 命令 — 复制文件或目录
    ///
    /// 支持 -r (递归复制目录)
    private static func cp(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var recursive = false
        var paths: [String] = []

        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "r", "R": recursive = true
                    case "f": break  // 忽略 -f（默认覆盖）
                    default: break
                    }
                }
            } else {
                paths.append(arg)
            }
        }

        if paths.count < 2 {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "cp: missing destination file operand after '\(paths.first ?? "")'\n",
                exitCode: 1,
                isError: true
            )
        }

        let srcPath = resolvePath(paths[0], workingDir: workingDir)
        let dstRaw = paths[paths.count - 1]
        let dstPath = resolvePath(dstRaw, workingDir: workingDir)

        let fm = FileManager.default

        // 检查源文件存在
        if !fm.fileExists(atPath: srcPath) {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "cp: \(paths[0]): No such file or directory\n",
                exitCode: 1,
                isError: true
            )
        }

        // 检查源是否是目录
        var srcIsDir: ObjCBool = false
        fm.fileExists(atPath: srcPath, isDirectory: &srcIsDir)

        if srcIsDir.boolValue && !recursive {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "cp: \(paths[0]): is a directory (not copied)\n",
                exitCode: 1,
                isError: true
            )
        }

        // 确定目标路径
        var finalDstPath = dstPath
        var dstIsDir: ObjCBool = false
        if fm.fileExists(atPath: dstPath, isDirectory: &dstIsDir) && dstIsDir.boolValue {
            // 目标是目录，复制到目录内
            let srcName = (srcPath as NSString).lastPathComponent
            finalDstPath = (dstPath as NSString).appendingPathComponent(srcName)
        }

        do {
            // 如果目标已存在，先删除（cp 默认覆盖）
            if fm.fileExists(atPath: finalDstPath) {
                try fm.removeItem(atPath: finalDstPath)
            }

            // copyItem 自动处理文件和目录（已通过 -r 检查）
            try fm.copyItem(atPath: srcPath, toPath: finalDstPath)
        } catch {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "cp: \(error.localizedDescription)\n",
                exitCode: 1,
                isError: true
            )
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            isError: false
        )
    }

    // MARK: - mv

    /// mv 命令 — 移动/重命名文件
    private static func mv(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        let paths = args.filter { !$0.hasPrefix("-") || $0 == "-" }

        if paths.count < 2 {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "mv: missing destination file operand after '\(paths.first ?? "")'\n",
                exitCode: 1,
                isError: true
            )
        }

        let srcPath = resolvePath(paths[0], workingDir: workingDir)
        let dstRaw = paths[paths.count - 1]
        let dstPath = resolvePath(dstRaw, workingDir: workingDir)

        let fm = FileManager.default

        if !fm.fileExists(atPath: srcPath) {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "mv: \(paths[0]): No such file or directory\n",
                exitCode: 1,
                isError: true
            )
        }

        // 确定目标路径
        var finalDstPath = dstPath
        var dstIsDir: ObjCBool = false
        if fm.fileExists(atPath: dstPath, isDirectory: &dstIsDir) && dstIsDir.boolValue {
            let srcName = (srcPath as NSString).lastPathComponent
            finalDstPath = (dstPath as NSString).appendingPathComponent(srcName)
        }

        do {
            // 如果目标已存在且不是目录，覆盖
            if fm.fileExists(atPath: finalDstPath) {
                var finalIsDir: ObjCBool = false
                fm.fileExists(atPath: finalDstPath, isDirectory: &finalIsDir)
                if !finalIsDir.boolValue {
                    try fm.removeItem(atPath: finalDstPath)
                }
            }

            try fm.moveItem(atPath: srcPath, toPath: finalDstPath)
        } catch {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "mv: \(error.localizedDescription)\n",
                exitCode: 1,
                isError: true
            )
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            isError: false
        )
    }

    // MARK: - head

    /// head 命令 — 输出文件前 N 行
    ///
    /// 默认 10 行，支持 -n N 或 -N 指定行数
    private static func head(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var lineCount = 10
        var filePaths: [String] = []
        var showHeaders = false  // 多文件时显示文件名头

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-n" {
                i += 1
                if i < args.count, let n = Int(args[i]) {
                    lineCount = n
                }
            } else if arg.hasPrefix("-n") {
                let numStr = String(arg.dropFirst(2))
                if let n = Int(numStr) {
                    lineCount = n
                }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                let numStr = String(arg.dropFirst())
                if let n = Int(numStr) {
                    lineCount = n
                }
            } else {
                filePaths.append(arg)
            }
            i += 1
        }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "head: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        if filePaths.count > 1 {
            showHeaders = true
        }

        var stdout = ""
        var stderr = ""
        var hasError = false

        for (index, rawPath) in filePaths.enumerated() {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if !FileManager.default.fileExists(atPath: resolvedPath) {
                stderr += "head: \(rawPath): No such file or directory\n"
                hasError = true
                continue
            }

            guard let data = FileManager.default.contents(atPath: resolvedPath),
                  let content = String(data: data, encoding: .utf8) else {
                stderr += "head: \(rawPath): Permission denied\n"
                hasError = true
                continue
            }

            if showHeaders {
                if index > 0 { stdout += "\n" }
                stdout += "==> \(rawPath) <==\n"
            }

            let lines = content.components(separatedBy: "\n")
            // 如果文件以 \n 结尾，componentsSeparatedBy 会多产生一个空字符串
            let actualLines = content.hasSuffix("\n") ? Array(lines.dropLast()) : lines
            let outputLines = Array(actualLines.prefix(lineCount))
            stdout += outputLines.joined(separator: "\n")
            if !outputLines.isEmpty {
                stdout += "\n"
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - tail

    /// tail 命令 — 输出文件后 N 行
    ///
    /// 默认 10 行，支持 -n N 或 -N 指定行数
    private static func tail(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var lineCount = 10
        var filePaths: [String] = []
        var showHeaders = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-n" {
                i += 1
                if i < args.count, let n = Int(args[i]) {
                    lineCount = n
                }
            } else if arg.hasPrefix("-n") {
                let numStr = String(arg.dropFirst(2))
                if let n = Int(numStr) {
                    lineCount = n
                }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                let numStr = String(arg.dropFirst())
                if let n = Int(numStr) {
                    lineCount = n
                }
            } else {
                filePaths.append(arg)
            }
            i += 1
        }

        if filePaths.isEmpty {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "tail: missing file operand\n",
                exitCode: 1,
                isError: true
            )
        }

        if filePaths.count > 1 {
            showHeaders = true
        }

        var stdout = ""
        var stderr = ""
        var hasError = false

        for (index, rawPath) in filePaths.enumerated() {
            let resolvedPath = resolvePath(rawPath, workingDir: workingDir)

            if !FileManager.default.fileExists(atPath: resolvedPath) {
                stderr += "tail: \(rawPath): No such file or directory\n"
                hasError = true
                continue
            }

            guard let data = FileManager.default.contents(atPath: resolvedPath),
                  let content = String(data: data, encoding: .utf8) else {
                stderr += "tail: \(rawPath): Permission denied\n"
                hasError = true
                continue
            }

            if showHeaders {
                if index > 0 { stdout += "\n" }
                stdout += "==> \(rawPath) <==\n"
            }

            let lines = content.components(separatedBy: "\n")
            let actualLines = content.hasSuffix("\n") ? Array(lines.dropLast()) : lines
            let startIndex = max(0, actualLines.count - lineCount)
            let outputLines = Array(actualLines[startIndex...])
            stdout += outputLines.joined(separator: "\n")
            if !outputLines.isEmpty {
                stdout += "\n"
            }
        }

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: hasError ? 1 : 0,
            isError: hasError
        )
    }

    // MARK: - find

    /// find 命令 — 递归搜索文件系统
    ///
    /// 支持的参数：
    /// - `<path>`: 搜索起始路径（默认 "."）
    /// - `-name <pattern>`: 按文件名 glob 匹配（支持 * 和 ?）
    /// - `-iname <pattern>`: 按文件名 glob 匹配（不区分大小写）
    /// - `-type f`: 只匹配普通文件
    /// - `-type d`: 只匹配目录
    /// - `-maxdepth <N>`: 限制递归深度
    ///
    /// 不支持的参数（静默忽略）：-perm, -user, -group, -size, -mtime, -exec, -delete, -print0
    private static func find(args: [String], workingDir: String) -> RuntimeExecutor.ExecutionResult {
        var searchPath: String? = nil
        var namePattern: String? = nil
        var caseInsensitive = false
        var typeFilter: String? = nil  // "f" or "d"
        var maxDepth: Int? = nil

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-name":
                i += 1
                if i < args.count {
                    namePattern = args[i]
                }
            case "-iname":
                i += 1
                if i < args.count {
                    namePattern = args[i]
                    caseInsensitive = true
                }
            case "-type":
                i += 1
                if i < args.count {
                    typeFilter = args[i]
                }
            case "-maxdepth":
                i += 1
                if i < args.count, let depth = Int(args[i]) {
                    maxDepth = depth
                }
            case "-not", "-a", "-and", "-o", "-or":
                // 逻辑运算符 — 当前简化实现忽略，仅支持单条件
                break
            default:
                // 以 - 开头的未知 flag 静默忽略；其他视为路径
                if !arg.hasPrefix("-") && searchPath == nil {
                    searchPath = arg
                }
            }
            i += 1
        }

        // 默认搜索路径为当前目录
        let rawSearchPath = searchPath ?? "."
        let resolvedSearchPath = resolvePath(rawSearchPath, workingDir: workingDir)

        let fm = FileManager.default

        // 检查路径是否存在
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: resolvedSearchPath, isDirectory: &isDir) {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "find: \(rawSearchPath): No such file or directory\n",
                exitCode: 1,
                isError: true
            )
        }

        var results: [String] = []

        // 编译 glob 正则（如果指定了 -name/-iname）
        let nameRegex: NSRegularExpression? = {
            guard let pattern = namePattern else { return nil }
            return compileGlob(pattern: pattern, caseInsensitive: caseInsensitive)
        }()

        // 检查单个条目是否匹配过滤条件
        let matchesFilters: (String, Bool) -> Bool = { (name: String, isDirectory: Bool) in
            // -type 过滤
            if let tf = typeFilter {
                if tf == "f" && isDirectory { return false }
                if tf == "d" && !isDirectory { return false }
            }
            // -name/-iname 过滤
            if let regex = nameRegex {
                let matchName = caseInsensitive ? name.lowercased() : name
                let range = NSRange(matchName.startIndex..., in: matchName)
                if regex.firstMatch(in: matchName, options: [], range: range) == nil {
                    return false
                }
            }
            return true
        }

        // 构建显示路径：保留用户输入的搜索路径前缀
        // find . → ./file.txt, find src → src/file.txt, find /abs → /abs/file.txt
        let displayPrefix: String = rawSearchPath
        // 规范化前缀：移除末尾的 /（除非是根路径 "/"）
        let normalizedPrefix = (displayPrefix.hasSuffix("/") && displayPrefix != "/")
            ? String(displayPrefix.dropLast())
            : displayPrefix

        // 构建绝对路径前缀（用于从 fileURL.path 中截取相对路径）
        let absPrefix = resolvedSearchPath.hasSuffix("/") ? resolvedSearchPath : resolvedSearchPath + "/"

        // 检查根路径本身是否匹配
        let rootName = (resolvedSearchPath as NSString).lastPathComponent
        let rootIsDir = isDir.boolValue
        if matchesFilters(rootName, rootIsDir) {
            results.append(normalizedPrefix)
        }

        // 如果是目录，递归遍历
        if rootIsDir {
            let searchURL = URL(fileURLWithPath: resolvedSearchPath)
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .nameKey]

            let enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
            // 注意：find 默认包含隐藏文件（.git 等），不使用 .skipsHiddenFiles

            guard let enumerator = fm.enumerator(
                at: searchURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: enumeratorOptions
            ) else {
                return RuntimeExecutor.ExecutionResult(
                    stdout: "",
                    stderr: "find: cannot enumerate '\(rawSearchPath)'\n",
                    exitCode: 1,
                    isError: true
                )
            }

            for case let fileURL in enumerator {
                // 获取文件属性
                let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
                let isDirectory = resourceValues?.isDirectory ?? false
                let name = resourceValues?.name ?? fileURL.lastPathComponent

                // -maxdepth 过滤：计算当前深度
                if let maxD = maxDepth {
                    let relativePath = fileURL.path.replacingOccurrences(of: absPrefix, with: "")
                    let depth = relativePath.split(separator: "/").count
                    if depth > maxD {
                        // 超过最大深度，跳过此条目及其子目录
                        enumerator.skipDescendants()
                        continue
                    }
                }

                // 检查是否匹配过滤条件
                guard matchesFilters(name, isDirectory) else {
                    continue
                }

                // 构建显示路径
                let relativePath = fileURL.path.replacingOccurrences(of: absPrefix, with: "")
                let displayPath: String
                if normalizedPrefix == "/" {
                    displayPath = "/" + relativePath
                } else if normalizedPrefix == "." {
                    displayPath = "./" + relativePath
                } else {
                    displayPath = normalizedPrefix + "/" + relativePath
                }

                results.append(displayPath)
            }
        }

        let stdout = results.isEmpty ? "" : (results.joined(separator: "\n") + "\n")

        return RuntimeExecutor.ExecutionResult(
            stdout: stdout,
            stderr: "",
            exitCode: 0,
            isError: false
        )
    }

    // MARK: - Utility Functions

    /// 检查命令是否包含 shell 操作符
    /// 含操作符的命令需要 ios_system parser 处理，不走原生路径
    private static func containsShellOperators(_ command: String) -> Bool {
        if command.contains("&&") || command.contains("||") || command.contains(";") {
            return true
        }
        // 检查管道符和重定向符
        let shellOperators: Set<Character> = ["|", ">", "<"]
        return command.contains(where: { shellOperators.contains($0) })
    }

    /// 命令分词 — 将命令字符串拆分为 token 数组
    /// 支持单引号和双引号
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false

        for char in command {
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// 路径解析 — 将相对路径解析为绝对路径
    ///
    /// - 绝对路径（以 / 开头）：原样返回
    /// - Tilde 路径（以 ~ 开头）：展开为 HOME 目录
    /// - 相对路径：基于 workingDir 拼接
    private static func resolvePath(_ path: String, workingDir: String) -> String {
        if path.hasPrefix("/") {
            // 绝对路径
            return path
        } else if path == "~" {
            // ~ → HOME
            return NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            // ~/path → HOME/path
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path == "." {
            // 当前目录
            return workingDir
        } else if path.hasPrefix("./") {
            // ./path → workingDir/path
            return (workingDir as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path == ".." {
            // 上级目录
            return (workingDir as NSString).deletingLastPathComponent
        } else if path.hasPrefix("../") {
            // ../path → 上级目录/path
            let parent = (workingDir as NSString).deletingLastPathComponent
            return (parent as NSString).appendingPathComponent(String(path.dropFirst(3)))
        } else {
            // 相对路径 → 基于 workingDir 拼接
            return (workingDir as NSString).appendingPathComponent(path)
        }
    }

    /// 将 shell glob 模式编译为正则表达式
    ///
    /// 支持的通配符：
    /// - `*` — 匹配任意数量的字符（不含 /）
    /// - `?` — 匹配单个字符
    /// - `[abc]` — 字符类
    /// - `[a-z]` — 范围字符类
    /// - `[!abc]` — 取反字符类
    ///
    /// - Parameters:
    ///   - pattern: glob 模式字符串（如 "*.swift", "test?.ts"）
    ///   - caseInsensitive: 是否不区分大小写
    /// - Returns: 编译后的 NSRegularExpression
    private static func compileGlob(pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        var regexPattern = "^"

        var i = pattern.startIndex
        while i < pattern.endIndex {
            let char = pattern[i]
            switch char {
            case "*":
                // * 匹配任意字符序列（find 的 -name 中 * 不跨 /，但简化实现允许跨 /）
                regexPattern += ".*"
            case "?":
                // ? 匹配单个字符
                regexPattern += "."
            case ".":
                regexPattern += "\\."
            case "+", "(", ")", "{", "}", "|", "^", "$", "\\":
                regexPattern += "\\\(char)"
            case "[":
                // 字符类处理
                let nextIndex = pattern.index(after: i)
                if nextIndex < pattern.endIndex && pattern[nextIndex] == "!" {
                    regexPattern += "[^"
                    i = nextIndex  // 跳过 !，i 会在循环末尾 +1
                } else {
                    regexPattern += "["
                }
            case "]":
                regexPattern += "]"
            default:
                regexPattern += String(char)
            }
            i = pattern.index(after: i)
        }

        regexPattern += "$"

        var options: NSRegularExpression.Options = []
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }

        // 编译正则 — 如果失败则回退为匹配所有
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: options) else {
            runtimeLogger.warning("find: failed to compile glob pattern '\(pattern)', matching all files")
            return try! NSRegularExpression(pattern: ".*", options: options)
        }
        return regex
    }
}
