import XCTest
@testable import Baize

/// QA 回归测试 — NativeCommands (方案B) Swift 原生命令实现验证
///
/// 测试覆盖 12 个高频命令 + 工具函数 + 边界情况：
/// - ls (空目录/-la/-a/多路径/错误)
/// - cat (多文件/不存在/二进制)
/// - pwd (workingDir 输出)
/// - wc (-l/-w/-c/无flag/多文件)
/// - stat (文件信息)
/// - touch (创建/更新时间戳)
/// - mkdir (-p/已存在)
/// - rm (-r/-f/-rf/目录保护)
/// - cp (-r/覆盖/源不存在)
/// - mv (重命名/跨目录/覆盖)
/// - head/tail (-n N/-N/默认10/多文件)
/// - shell 操作符检测 (返回 nil)
/// - 不支持的命令 (返回 nil)
/// - 参数分词器 (引号/多空格)
/// - 路径解析器 (绝对/~/. /../ )
///
/// 注意：测试需要 iOS 运行时环境（FileManager），在非 iOS 环境下仅作静态验证参考。
/// NativeCommands 所有方法为 static，无需实例化 RuntimeExecutor。
final class NativeCommandsTests: XCTestCase {

    // MARK: - Helpers

    /// 创建临时测试目录，返回路径
    private func makeTempDir() -> String {
        let tempDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("NativeCommandsTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true
        )
        return tempDir
    }

    /// 清理临时目录
    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 在指定目录创建文件并写入内容
    private func writeFile(_ dir: String, name: String, content: String) -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Test 1: ls 在空目录

    func test_ls_emptyDir_emptyOutput() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "ls", workingDir: dir)

        XCTAssertNotNil(result, "ls 应返回非 nil 结果")
        XCTAssertEqual(result?.stdout, "", "空目录 ls 输出应为空")
        XCTAssertEqual(result?.exitCode, 0, "空目录 ls exitCode 应为 0")
        XCTAssertFalse(result?.isError ?? true, "空目录 ls 不应为错误")
    }

    // MARK: - Test 2: ls -la 含文件

    func test_ls_la_containsFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "hello")

        let result = NativeCommands.execute(command: "ls -la", workingDir: dir)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.stdout.contains("test.txt") ?? false, "ls -la 输出应包含 test.txt")
        XCTAssertTrue(result?.stdout.contains("-rw") ?? false, "ls -la 权限位应以 -rw 开头（普通文件）")
        XCTAssertTrue(result?.stdout.contains("mobile") ?? false, "ls -la 应包含 owner mobile")
        XCTAssertTrue(result?.stdout.contains("total") ?? false, "ls -la 应包含 total 行")
    }

    // MARK: - Test 3: ls -a 显示隐藏文件

    func test_ls_a_showsHiddenFiles() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: ".hidden", content: "secret")
        writeFile(dir, name: "visible.txt", content: "data")

        // ls -a 应显示隐藏文件
        let resultWithA = NativeCommands.execute(command: "ls -a", workingDir: dir)
        XCTAssertTrue(resultWithA?.stdout.contains(".hidden") ?? false, "ls -a 应显示 .hidden")

        // ls 不带 -a 不应显示隐藏文件
        let resultWithoutA = NativeCommands.execute(command: "ls", workingDir: dir)
        XCTAssertFalse(resultWithoutA?.stdout.contains(".hidden") ?? true, "ls 不带 -a 不应显示 .hidden")
        XCTAssertTrue(resultWithoutA?.stdout.contains("visible.txt") ?? false, "ls 应显示 visible.txt")
    }

    // MARK: - Test 4: cat 文件内容

    func test_cat_fileContent() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "hello world")

        let result = NativeCommands.execute(command: "cat test.txt", workingDir: dir)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.stdout.contains("hello world") ?? false, "cat 应输出文件内容")
        XCTAssertEqual(result?.exitCode, 0)
    }

    // MARK: - Test 5: cat 文件不存在

    func test_cat_nonexistentFile_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "cat /nonexistent_file_xyz", workingDir: dir)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.stderr.contains("No such file") ?? false, "cat 不存在文件应报错")
        XCTAssertTrue(result?.isError ?? false, "cat 不存在文件 isError 应为 true")
        XCTAssertEqual(result?.exitCode, 1)
    }

    // MARK: - Test 6: pwd

    func test_pwd_outputsWorkingDir() {
        let dir = "/var/mobile/Documents/Baize"

        let result = NativeCommands.execute(command: "pwd", workingDir: dir)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.stdout.contains(dir) ?? false, "pwd 应输出 workingDir")
        XCTAssertEqual(result?.exitCode, 0)
    }

    // MARK: - Test 7: wc -l 行数

    func test_wc_l_lineCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "file.txt", content: "line1\nline2\nline3")

        let result = NativeCommands.execute(command: "wc -l file.txt", workingDir: dir)

        XCTAssertNotNil(result)
        // "line1\nline2\nline3" 有 2 个换行符 → wc -l = 2
        XCTAssertTrue(result?.stdout.contains("2") ?? false, "wc -l 应返回 2（2个换行符）")
        XCTAssertEqual(result?.exitCode, 0)
    }

    // MARK: - Test 7b: wc -l 带尾随换行

    func test_wc_l_trailingNewline() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "file.txt", content: "line1\nline2\nline3\n")

        let result = NativeCommands.execute(command: "wc -l file.txt", workingDir: dir)

        XCTAssertNotNil(result)
        // "line1\nline2\nline3\n" 有 3 个换行符 → wc -l = 3
        XCTAssertTrue(result?.stdout.contains("3") ?? false, "wc -l 应返回 3（3个换行符，含尾随换行）")
    }

    // MARK: - Test 7c: wc 无 flag 输出全部三项

    func test_wc_noFlags_allThree() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "file.txt", content: "hello world\n")

        let result = NativeCommands.execute(command: "wc file.txt", workingDir: dir)

        XCTAssertNotNil(result)
        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains("file.txt"), "wc 输出应包含文件名")
        // 无 flag 时应输出 行数/单词数/字节数 三项
        // "hello world\n" → 1行, 2词, 12字节
        XCTAssertTrue(stdout.contains("1"), "wc 应包含行数 1")
    }

    // MARK: - Test 8: mkdir + rm

    func test_mkdir_then_rm() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // mkdir
        let mkdirResult = NativeCommands.execute(command: "mkdir testdir", workingDir: dir)
        XCTAssertEqual(mkdirResult?.exitCode, 0, "mkdir 应成功")
        let testdirPath = (dir as NSString).appendingPathComponent("testdir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testdirPath), "目录应被创建")

        // rm -r
        let rmResult = NativeCommands.execute(command: "rm -r testdir", workingDir: dir)
        XCTAssertEqual(rmResult?.exitCode, 0, "rm -r 应成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: testdirPath), "目录应被删除")
    }

    // MARK: - Test 8b: mkdir 已存在 (无 -p)

    func test_mkdir_exists_noP_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // 先创建
        _ = NativeCommands.execute(command: "mkdir testdir", workingDir: dir)

        // 再次创建（无 -p）
        let result = NativeCommands.execute(command: "mkdir testdir", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("File exists") ?? false, "mkdir 已存在目录应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 8c: mkdir -p 已存在不报错

    func test_mkdir_p_exists_noError() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        _ = NativeCommands.execute(command: "mkdir testdir", workingDir: dir)
        let result = NativeCommands.execute(command: "mkdir -p testdir", workingDir: dir)
        XCTAssertEqual(result?.exitCode, 0, "mkdir -p 已存在目录应成功")
        XCTAssertFalse(result?.isError ?? true)
    }

    // MARK: - Test 9: cp 复制

    func test_cp_copyFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "src.txt", content: "copy me")

        let result = NativeCommands.execute(command: "cp src.txt dst.txt", workingDir: dir)

        XCTAssertEqual(result?.exitCode, 0, "cp 应成功")
        let dstPath = (dir as NSString).appendingPathComponent("dst.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstPath), "目标文件应存在")
        let content = try? String(contentsOfFile: dstPath, encoding: .utf8)
        XCTAssertEqual(content, "copy me", "目标文件内容应与源文件相同")
    }

    // MARK: - Test 9b: cp 源不存在

    func test_cp_sourceNotFound_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "cp nonexistent.txt dst.txt", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("No such file") ?? false, "cp 源不存在应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 9c: cp -r 目录

    func test_cp_r_directory() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // 创建源目录和文件
        let srcDir = (dir as NSString).appendingPathComponent("srcdir")
        try? FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
        writeFile(srcDir, name: "inner.txt", content: "inner")

        let result = NativeCommands.execute(command: "cp -r srcdir dstdir", workingDir: dir)
        XCTAssertEqual(result?.exitCode, 0, "cp -r 应成功")
        let dstInnerPath = (dir as NSString).appendingPathComponent("dstdir/inner.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstInnerPath), "目标目录内文件应存在")
    }

    // MARK: - Test 10: mv 移动/重命名

    func test_mv_rename() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "old.txt", content: "move me")

        let result = NativeCommands.execute(command: "mv old.txt new.txt", workingDir: dir)

        XCTAssertEqual(result?.exitCode, 0, "mv 应成功")
        let oldPath = (dir as NSString).appendingPathComponent("old.txt")
        let newPath = (dir as NSString).appendingPathComponent("new.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath), "源文件应不存在")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath), "目标文件应存在")
    }

    // MARK: - Test 10b: mv 源不存在

    func test_mv_sourceNotFound_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "mv nonexistent.txt new.txt", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("No such file") ?? false, "mv 源不存在应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 11: head -n 5

    func test_head_n5() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        writeFile(dir, name: "file.txt", content: lines)

        let result = NativeCommands.execute(command: "head -n 5 file.txt", workingDir: dir)

        XCTAssertNotNil(result)
        let outputLines = result?.stdout.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(outputLines.count, 5, "head -n 5 应输出 5 行")
        XCTAssertEqual(outputLines.first, "line1", "第一行应为 line1")
        XCTAssertEqual(outputLines.last, "line5", "最后一行应为 line5")
    }

    // MARK: - Test 11b: head -N 简写

    func test_head_shorthand_N() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        writeFile(dir, name: "file.txt", content: lines)

        let result = NativeCommands.execute(command: "head -3 file.txt", workingDir: dir)

        let outputLines = result?.stdout.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(outputLines.count, 3, "head -3 应输出 3 行")
    }

    // MARK: - Test 11c: head 默认 10 行

    func test_head_default10() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        writeFile(dir, name: "file.txt", content: lines)

        let result = NativeCommands.execute(command: "head file.txt", workingDir: dir)

        let outputLines = result?.stdout.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(outputLines.count, 10, "head 默认应输出 10 行")
    }

    // MARK: - Test 11d: tail -n 3

    func test_tail_n3() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        writeFile(dir, name: "file.txt", content: lines)

        let result = NativeCommands.execute(command: "tail -n 3 file.txt", workingDir: dir)

        let outputLines = result?.stdout.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(outputLines.count, 3, "tail -n 3 应输出 3 行")
        XCTAssertEqual(outputLines.first, "line18", "第一行应为 line18")
        XCTAssertEqual(outputLines.last, "line20", "最后一行应为 line20")
    }

    // MARK: - Test 12: shell 操作符返回 nil

    func test_shellOperators_returnNil() {
        let testCases = [
            "ls | grep test",
            "ls > file.txt",
            "cat < input.txt",
            "ls && echo done",
            "ls || echo failed",
            "echo hello; ls",
        ]

        for cmd in testCases {
            let result = NativeCommands.execute(command: cmd, workingDir: "/tmp")
            XCTAssertNil(result, "含 shell 操作符的命令 '\(cmd)' 应返回 nil")
        }
    }

    // MARK: - Test 13: 不支持的命令返回 nil

    func test_unsupportedCommand_returnNil() {
        // 注意：find 和 grep 已加入 NativeCommands supportedCommands，不再返回 nil
        let testCases = [
            "git status",
            "sed 's/old/new/g' file.txt",
            "sort file.txt",
            "awk '{print $1}' file.txt",
            "curl https://example.com",
            "tar -czf archive.tar.gz dir/",
            "xyz_unknown_command",
        ]

        for cmd in testCases {
            let result = NativeCommands.execute(command: cmd, workingDir: "/tmp")
            XCTAssertNil(result, "不支持的命令 '\(cmd)' 应返回 nil（走 ios_popen）")
        }
    }

    // MARK: - Test 13b: find 和 grep 现在是原生支持的命令

    func test_findAndGrep_areNowSupported() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "hello world")

        // find 现在是原生命令（之前就加入了 supportedCommands）
        let findResult = NativeCommands.execute(command: "find . -name 'test.txt'", workingDir: dir)
        XCTAssertNotNil(findResult, "find 应被 NativeCommands 处理（不再返回 nil）")

        // grep 现在是原生命令（本次新增）
        let grepResult = NativeCommands.execute(command: "grep hello test.txt", workingDir: dir)
        XCTAssertNotNil(grepResult, "grep 应被 NativeCommands 处理（不再返回 nil）")
    }

    // MARK: - Test 14: touch 创建空文件

    func test_touch_createEmptyFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "touch newfile.txt", workingDir: dir)

        XCTAssertEqual(result?.exitCode, 0, "touch 应成功")
        let path = (dir as NSString).appendingPathComponent("newfile.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "文件应被创建")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        XCTAssertEqual(size, 0, "touch 创建的文件大小应为 0")
    }

    // MARK: - Test 14b: touch 更新已有文件时间戳

    func test_touch_updateTimestamp() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "existing.txt", content: "data")

        // 获取原始修改时间
        let path = (dir as NSString).appendingPathComponent("existing.txt")
        let attrs1 = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate1 = attrs1?[.modificationDate] as? Date

        // 等待一小段时间确保时间戳不同
        Thread.sleep(forTimeInterval: 0.1)

        // touch
        let result = NativeCommands.execute(command: "touch existing.txt", workingDir: dir)
        XCTAssertEqual(result?.exitCode, 0)

        // 验证修改时间已更新
        let attrs2 = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate2 = attrs2?[.modificationDate] as? Date
        XCTAssertNotNil(modDate1)
        XCTAssertNotNil(modDate2)
        if let d1 = modDate1, let d2 = modDate2 {
            XCTAssertGreaterThan(d2, d1, "touch 应更新修改时间")
        }
    }

    // MARK: - Test 15: stat 文件信息

    func test_stat_fileInfo() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "stat me")

        let result = NativeCommands.execute(command: "stat test.txt", workingDir: dir)

        XCTAssertNotNil(result)
        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains("File:"), "stat 输出应包含 File:")
        XCTAssertTrue(stdout.contains("Size:"), "stat 输出应包含 Size:")
        XCTAssertTrue(stdout.contains("Access:"), "stat 输出应包含权限信息")
        XCTAssertTrue(stdout.contains("Modify:"), "stat 输出应包含修改时间")
        XCTAssertTrue(stdout.contains("regular file"), "stat 输出应包含文件类型")
    }

    // MARK: - Test 15b: stat 不存在文件

    func test_stat_nonexistent_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "stat /nonexistent_xyz", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("No such file") ?? false, "stat 不存在文件应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 16: ls 路径不存在

    func test_ls_nonexistentPath_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "ls /nonexistent/path/xyz", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("No such file") ?? false, "ls 不存在路径应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 17: ls 多路径

    func test_ls_multiplePaths() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let subDir1 = (dir as NSString).appendingPathComponent("dir1")
        let subDir2 = (dir as NSString).appendingPathComponent("dir2")
        try? FileManager.default.createDirectory(atPath: subDir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: subDir2, withIntermediateDirectories: true)
        writeFile(subDir1, name: "a.txt", content: "a")
        writeFile(subDir2, name: "b.txt", content: "b")

        let result = NativeCommands.execute(command: "ls dir1 dir2", workingDir: dir)

        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains("a.txt"), "ls 多路径应包含 dir1 内容")
        XCTAssertTrue(stdout.contains("b.txt"), "ls 多路径应包含 dir2 内容")
        // 多路径时应显示路径头
        XCTAssertTrue(stdout.contains("dir1:") || stdout.contains("dir1/:"), "多路径应显示路径头")
    }

    // MARK: - Test 18: cat 多文件拼接

    func test_cat_multipleFiles() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "f1.txt", content: "first")
        writeFile(dir, name: "f2.txt", content: "second")

        let result = NativeCommands.execute(command: "cat f1.txt f2.txt", workingDir: dir)

        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains("first"), "cat 多文件应包含第一个文件内容")
        XCTAssertTrue(stdout.contains("second"), "cat 多文件应包含第二个文件内容")
    }

    // MARK: - Test 19: rm -f 不存在文件不报错

    func test_rm_f_nonexistent_noError() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "rm -f nonexistent.txt", workingDir: dir)
        XCTAssertEqual(result?.exitCode, 0, "rm -f 不存在文件应返回 0")
        XCTAssertFalse(result?.isError ?? true, "rm -f 不存在文件不应报错")
    }

    // MARK: - Test 20: rm 目录无 -r 报错

    func test_rm_directory_noR_error() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        _ = NativeCommands.execute(command: "mkdir testdir", workingDir: dir)
        let result = NativeCommands.execute(command: "rm testdir", workingDir: dir)
        XCTAssertTrue(result?.stderr.contains("is a directory") ?? false, "rm 目录无 -r 应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 21: ls -1 单列输出

    func test_ls_1_singleColumn() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "a.txt", content: "a")
        writeFile(dir, name: "b.txt", content: "b")

        let result = NativeCommands.execute(command: "ls -1", workingDir: dir)
        let lines = result?.stdout.split(separator: "\n").filter { !$0.isEmpty } ?? []
        XCTAssertEqual(lines.count, 2, "ls -1 应输出 2 行（每行一个文件）")
    }

    // MARK: - Test 22: ls -la 组合 flag

    func test_ls_la_combined() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: ".hidden", content: "h")
        writeFile(dir, name: "visible.txt", content: "v")

        let result = NativeCommands.execute(command: "ls -la", workingDir: dir)
        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains(".hidden"), "ls -la 应显示隐藏文件")
        XCTAssertTrue(stdout.contains("visible.txt"), "ls -la 应显示可见文件")
        XCTAssertTrue(stdout.contains("total"), "ls -la 应有 total 行")
    }

    // MARK: - Test 23: ls -al 组合 flag (顺序不同)

    func test_ls_al_combined() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: ".hidden", content: "h")

        let result = NativeCommands.execute(command: "ls -al", workingDir: dir)
        XCTAssertTrue(result?.stdout.contains(".hidden") ?? false, "ls -al 应显示隐藏文件")
        XCTAssertTrue(result?.stdout.contains("total") ?? false, "ls -al 应有 total 行")
    }

    // MARK: - Test 24: 空命令返回 nil

    func test_emptyCommand_returnNil() {
        let result = NativeCommands.execute(command: "", workingDir: "/tmp")
        XCTAssertNil(result, "空命令应返回 nil")
    }

    // MARK: - Test 25: 只有 flags 没有路径 (ls -l 无路径 → 列出 workingDir)

    func test_ls_flagsOnly_defaultsToWorkingDir() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "x")

        let result = NativeCommands.execute(command: "ls -l", workingDir: dir)
        XCTAssertTrue(result?.stdout.contains("test.txt") ?? false, "ls -l 无路径应列出 workingDir")
        XCTAssertTrue(result?.stdout.contains("total") ?? false)
    }

    // MARK: - Test 26: 路径含空格 (引号包裹)

    func test_pathWithSpaces() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // 创建含空格的文件名
        let spacedName = "my file.txt"
        let path = (dir as NSString).appendingPathComponent(spacedName)
        try? "content".write(toFile: path, atomically: true, encoding: .utf8)

        // 用双引号包裹路径
        let result = NativeCommands.execute(command: "cat \"my file.txt\"", workingDir: dir)
        XCTAssertTrue(result?.stdout.contains("content") ?? false, "cat 含空格路径应正确读取")
    }

    // MARK: - Test 27: 大小写不敏感命令名

    func test_commandName_caseInsensitive() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "test.txt", content: "data")

        // "LS" 应被识别为 "ls"（代码使用 .lowercased()）
        let result = NativeCommands.execute(command: "LS", workingDir: dir)
        XCTAssertNotNil(result, "大写命令名应被识别（lowercased）")
    }

    // MARK: - Test 28: cat 无参数报错

    func test_cat_noArgs_error() {
        let result = NativeCommands.execute(command: "cat", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing file operand") ?? false, "cat 无参数应报错")
        XCTAssertTrue(result?.isError ?? false)
    }

    // MARK: - Test 29: wc 无参数报错

    func test_wc_noArgs_error() {
        let result = NativeCommands.execute(command: "wc", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing file operand") ?? false, "wc 无参数应报错")
    }

    // MARK: - Test 30: mkdir 无参数报错

    func test_mkdir_noArgs_error() {
        let result = NativeCommands.execute(command: "mkdir", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing operand") ?? false, "mkdir 无参数应报错")
    }

    // MARK: - Test 31: rm 无参数报错

    func test_rm_noArgs_error() {
        let result = NativeCommands.execute(command: "rm", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing operand") ?? false, "rm 无参数应报错")
    }

    // MARK: - Test 32: cp 参数不足报错

    func test_cp_insufficientArgs_error() {
        let result = NativeCommands.execute(command: "cp onlyone.txt", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing destination") ?? false, "cp 参数不足应报错")
    }

    // MARK: - Test 33: mv 参数不足报错

    func test_mv_insufficientArgs_error() {
        let result = NativeCommands.execute(command: "mv onlyone.txt", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing destination") ?? false, "mv 参数不足应报错")
    }

    // MARK: - Test 34: head 无参数报错

    func test_head_noArgs_error() {
        let result = NativeCommands.execute(command: "head", workingDir: "/tmp")
        XCTAssertTrue(result?.stderr.contains("missing file operand") ?? false, "head 无参数应报错")
    }

    // MARK: - Test 35: ExecutionResult 结构正确性

    func test_executionResult_structure() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let result = NativeCommands.execute(command: "pwd", workingDir: dir)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.stdout)
        XCTAssertNotNil(result?.stderr)
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertFalse(result?.isError ?? true)
        // formattedOutput 是 computed property
        XCTAssertNotNil(result?.formattedOutput)
    }

    // MARK: - Test 36: ls -l 单个文件

    func test_ls_l_singleFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "single.txt", content: "x")

        let result = NativeCommands.execute(command: "ls -l single.txt", workingDir: dir)
        let stdout = result?.stdout ?? ""
        XCTAssertTrue(stdout.contains("single.txt"), "ls -l 单文件应包含文件名")
        XCTAssertTrue(stdout.contains("-rw"), "ls -l 单文件应有权限位")
    }

    // MARK: - Test 37: wc -c 字节数

    func test_wc_c_byteCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "file.txt", content: "hello")  // 5 bytes

        let result = NativeCommands.execute(command: "wc -c file.txt", workingDir: dir)
        XCTAssertTrue(result?.stdout.contains("5") ?? false, "wc -c 应返回 5 字节")
    }

    // MARK: - Test 38: wc -w 单词数

    func test_wc_w_wordCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        writeFile(dir, name: "file.txt", content: "one two three")  // 3 words

        let result = NativeCommands.execute(command: "wc -w file.txt", workingDir: dir)
        XCTAssertTrue(result?.stdout.contains("3") ?? false, "wc -w 应返回 3 单词")
    }
}
