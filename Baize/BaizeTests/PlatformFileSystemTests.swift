import XCTest
@testable import Baize

/// T02 Phase: 文件系统统一机制单元测试
///
/// 验证点：
/// 1. PlatformFileSystem 统一文件系统入口
/// 2. FileSystemStrategy 可切换（FileManager 为默认）
/// 3. FileSystemService 将写操作转发到 PlatformFileSystem
/// 4. PlatformFileSystem 策略选择逻辑
final class PlatformFileSystemTests: XCTestCase {

    private var tempRoot: String!
    private var platformFileSystem: PlatformFileSystem!
    private var fileSystemService: FileSystemService!

    override func setUp() async throws {
        try await super.setUp()

        // 使用独立临时目录，避免污染真实项目根目录
        let tempDir = NSTemporaryDirectory()
        tempRoot = (tempDir as NSString).appendingPathComponent("BaizeT02-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tempRoot,
            withIntermediateDirectories: true
        )

        platformFileSystem = PlatformFileSystem(rootPath: tempRoot, strategyType: .fileManager)
        fileSystemService = FileSystemService(rootPath: tempRoot, platformFileSystem: platformFileSystem)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
        fileSystemService = nil
        platformFileSystem = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - 1. 默认策略为 FileManager

    func test_init_defaultStrategyIsFileManager() async {
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .fileManager, "PlatformFileSystem 默认策略应为 FileManager")
    }

    // MARK: - 2. setStrategy 可切换策略

    func test_setStrategy_switchesToPosixSpawn() async {
        await platformFileSystem.setStrategy(.posixSpawn)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .posixSpawn, "setStrategy(.posixSpawn) 后当前策略应变更")
    }

    func test_setStrategy_switchesToIOSSystem() async {
        await platformFileSystem.setStrategy(.iosSystem)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .iosSystem, "setStrategy(.iosSystem) 后当前策略应变更")
    }

    func test_setStrategy_switchesBackToFileManager() async {
        await platformFileSystem.setStrategy(.posixSpawn)
        await platformFileSystem.setStrategy(.fileManager)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .fileManager, "setStrategy(.fileManager) 后可切回默认策略")
    }

    // MARK: - 3. PlatformFileSystem 统一文件读写

    func test_writeFileAndReadFile() async throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("test.txt")
        let content = "Hello, Baize T02!"

        try await platformFileSystem.writeFile(at: filePath, content: content)
        let read = try platformFileSystem.readFile(at: filePath)

        XCTAssertEqual(read, content, "写入后应能读取到相同内容")
    }

    func test_editFile() async throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("edit.txt")
        try await platformFileSystem.writeFile(at: filePath, content: "old content")

        let replaced = try await platformFileSystem.editFile(
            at: filePath,
            oldString: "old",
            newString: "new"
        )

        XCTAssertTrue(replaced, "editFile 应返回 true")
        let read = try platformFileSystem.readFile(at: filePath)
        XCTAssertEqual(read, "new content", "editFile 应完成字符串替换")
    }

    func test_createDirectory() async throws {
        let dirPath = (tempRoot as NSString).appendingPathComponent("subdir/nested")
        try await platformFileSystem.createDirectory(at: dirPath)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue, "createDirectory 应创建多级目录")
    }

    func test_deleteItem() async throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("delete_me.txt")
        try await platformFileSystem.writeFile(at: filePath, content: "bye")

        try await platformFileSystem.deleteItem(at: filePath)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: filePath),
            "deleteItem 应删除文件"
        )
    }

    func test_deleteItem_projectRoot_denied() async {
        let expectation = XCTestExpectation(description: "删除项目根目录应被拒绝")
        Task {
            do {
                try await platformFileSystem.deleteItem(at: tempRoot)
                XCTFail("删除项目根目录应抛出 permissionDenied")
            } catch {
                expectation.fulfill()
            }
        }
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - 4. FileSystemService 转发到 PlatformFileSystem

    func test_fileSystemService_writeFile() throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("service.txt")
        try fileSystemService.writeFile(at: filePath, content: "via FileSystemService")

        let read = try fileSystemService.readFile(at: filePath)
        XCTAssertEqual(read, "via FileSystemService", "FileSystemService.writeFile 应转发到 PlatformFileSystem")
    }

    func test_fileSystemService_createDirectory() throws {
        let dirPath = (tempRoot as NSString).appendingPathComponent("service_dir")
        try fileSystemService.createDirectory(at: dirPath)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue, "FileSystemService.createDirectory 应转发到 PlatformFileSystem")
    }

    func test_fileSystemService_deleteItem() throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("service_delete.txt")
        try fileSystemService.writeFile(at: filePath, content: "x")
        try fileSystemService.deleteItem(at: filePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func test_fileSystemService_editFile() throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("service_edit.txt")
        try fileSystemService.writeFile(at: filePath, content: "alpha beta")
        let replaced = try fileSystemService.editFile(at: filePath, oldString: "alpha", newString: "gamma")

        XCTAssertTrue(replaced)
        let read = try fileSystemService.readFile(at: filePath)
        XCTAssertEqual(read, "gamma beta")
    }

    // MARK: - 5. 策略选择逻辑

    func test_selectBestStrategy_prefersPosixSpawn() async {
        let capabilities = FileSystemCapabilities(fileManager: true, posixSpawn: true, iosSystem: true)
        await platformFileSystem.selectBestStrategy(basedOn: capabilities)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .posixSpawn, "优先级：posixSpawn > iosSystem > fileManager")
    }

    func test_selectBestStrategy_fallbackToIOSSystem() async {
        let capabilities = FileSystemCapabilities(fileManager: true, posixSpawn: false, iosSystem: true)
        await platformFileSystem.selectBestStrategy(basedOn: capabilities)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .iosSystem, "posixSpawn 不可用时回退到 iosSystem")
    }

    func test_selectBestStrategy_fallbackToFileManager() async {
        let capabilities = FileSystemCapabilities(fileManager: true, posixSpawn: false, iosSystem: false)
        await platformFileSystem.selectBestStrategy(basedOn: capabilities)
        let strategy = await platformFileSystem.currentStrategy()
        XCTAssertEqual(strategy, .fileManager, "全部不可用时回退到 fileManager")
    }

    // MARK: - 6. 静态能力探测不崩溃

    func test_probeCapabilities_returnsCapabilities() {
        let capabilities = PlatformFileSystem.probeCapabilities()
        XCTAssertTrue(capabilities.fileManager, "FileManager 始终可用")
        // posixSpawn 取决于 bundle 二进制是否存在，不做强制断言，但结构应完整
        XCTAssertTrue(capabilities.description.contains("fileManager="))
    }
}
