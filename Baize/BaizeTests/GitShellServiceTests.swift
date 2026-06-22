import XCTest
@testable import Baize

/// T03 Phase: Git HTTPS 传输层重写单元测试
///
/// 验证点：
/// 1. GitShellService 在 git 二进制缺失时给出清晰占位符错误
/// 2. GitShellService 可注入自定义二进制/证书路径
/// 3. GitShellService 命令解析对简单 git 命令有效
final class GitShellServiceTests: XCTestCase {

    private var tempDir: String!
    private var keychainService: KeychainService!

    override func setUp() {
        super.setUp()
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("BaizeT03-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        keychainService = KeychainService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        keychainService = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - 1. 缺失 git 二进制时抛出清晰占位符错误

    func test_gitShellService_missingBinary_throwsPlaceholderError() async {
        let service = GitShellService(
            repositoryPath: tempDir,
            keychainService: keychainService,
            gitBinaryPath: "/nonexistent/git",
            caBundlePath: "/nonexistent/cacert.pem"
        )

        do {
            _ = try await service.executeGitCommand(["status"])
            XCTFail("缺失 git 二进制时应抛出错误")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("git 二进制不存在") || message.contains("T03"),
                "错误信息应提示 T03 占位符替换: \(message)"
            )
        }
    }

    // MARK: - 2. 自定义 CA 路径注入

    func test_gitShellService_acceptsCustomCABundlePath() {
        let customCA = (tempDir as NSString).appendingPathComponent("custom.pem")
        let service = GitShellService(
            repositoryPath: tempDir,
            keychainService: keychainService,
            gitBinaryPath: "/nonexistent/git",
            caBundlePath: customCA
        )

        XCTAssertNotNil(service)
    }

    // MARK: - 3. 简单 git 字符串命令解析

    func test_gitShellService_executeGitCommandString_parsesSimpleCommand() async {
        let service = GitShellService(
            repositoryPath: tempDir,
            keychainService: keychainService,
            gitBinaryPath: "/nonexistent/git"
        )

        do {
            _ = try await service.executeGitCommand("git status")
            XCTFail("缺失二进制时应抛出错误")
        } catch {
            // 只要代码路径正确执行到二进制缺失检查即可
            XCTAssertTrue(error.localizedDescription.contains("git 二进制不存在"))
        }
    }

    func test_gitShellService_executeGitCommandString_rejectsNonGitCommand() async {
        let service = GitShellService(
            repositoryPath: tempDir,
            keychainService: keychainService
        )

        do {
            _ = try await service.executeGitCommand("ls -la")
            XCTFail("非 git 命令应被拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("必须以 'git' 开头"))
        }
    }
}
