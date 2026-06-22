import XCTest
@testable import Baize

/// T05 Phase: 子 Agent 隔离 + Skills + Memory 改造单元测试
///
/// 验证点：
/// 1. SubAgentContext 创建独立的文件系统/权限/会话
/// 2. MemoryStore 通过 PlatformFileSystem 写入
/// 3. PlatformFileSystem 三种策略均支持 appendFile（PosixSpawn/IOSSystem 回退 FileManager）
/// 4. SkillRegistry 提供 getSkill 查询
final class SubAgentSkillMemoryTests: XCTestCase {

    private var tempRoot: String!
    private var parentPFS: PlatformFileSystem!
    private var fileSystemService: FileSystemService!
    private var runtimeExecutor: RuntimeExecutor!
    private var toolRegistry: ToolRegistry!

    override func setUp() async throws {
        try await super.setUp()

        tempRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("BaizeT05-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        parentPFS = PlatformFileSystem(rootPath: tempRoot, strategyType: .fileManager)
        fileSystemService = FileSystemService(rootPath: tempRoot, platformFileSystem: parentPFS)
        runtimeExecutor = RuntimeExecutor()
        toolRegistry = ToolRegistry(
            fileSystemService: fileSystemService,
            platformFileSystem: parentPFS,
            runtimeExecutor: runtimeExecutor
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
        toolRegistry = nil
        runtimeExecutor = nil
        fileSystemService = nil
        parentPFS = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - 1. SubAgentContext 隔离

    func test_subAgentContext_inheritsParentStrategy() async throws {
        let subContext = await SubAgentContext(
            projectPath: tempRoot,
            parentPlatformFileSystem: parentPFS,
            toolRegistry: toolRegistry
        )

        let parentStrategy = await parentPFS.currentStrategy()
        let subStrategy = await subContext.platformFileSystem.currentStrategy()

        XCTAssertEqual(subStrategy, parentStrategy, "子 Agent 应继承父 Agent 的文件系统策略")
        XCTAssertEqual(subStrategy, .fileManager, "默认策略应为 FileManager")
    }

    func test_subAgentContext_permissionEngine_isIndependent() async throws {
        let subContext = await SubAgentContext(
            projectPath: tempRoot,
            parentPlatformFileSystem: parentPFS,
            toolRegistry: toolRegistry
        )

        let mode = await subContext.permissionEngine.getMode()
        XCTAssertEqual(mode, .default, "子 Agent 的 PermissionEngine 应为 .default，不继承父 Agent 状态")
    }

    func test_subAgentContext_conversationSession_isIndependent() async throws {
        let subContext = await SubAgentContext(
            projectPath: tempRoot,
            parentPlatformFileSystem: parentPFS,
            toolRegistry: toolRegistry
        )

        XCTAssertEqual(subContext.conversationSession.projectPath, tempRoot)
        XCTAssertTrue(subContext.conversationSession.messages.isEmpty, "子 Agent 会话应为空")
    }

    func test_subAgentContext_fileSystemService_usesIndependentPlatformFileSystem() async throws {
        let subContext = await SubAgentContext(
            projectPath: tempRoot,
            parentPlatformFileSystem: parentPFS,
            toolRegistry: toolRegistry
        )

        let subStrategy = await subContext.fileSystemService.platformFileSystem.currentStrategy()
        XCTAssertEqual(subStrategy, .fileManager, "子 Agent 的 FileSystemService 应使用独立 PlatformFileSystem")
    }

    // MARK: - 2. MemoryStore 通过 PlatformFileSystem 写入

    func test_memoryStore_appendMemory_viaPlatformFileSystem() async throws {
        let memoryStore = MemoryStore(platformFileSystem: parentPFS)
        let filePath = BaizePath.userMemoryDir + "/memories.jsonl"

        // 清理可能存在的旧数据，确保测试可重复
        try? FileManager.default.removeItem(atPath: filePath)

        try await memoryStore.appendMemory(
            scope: .user,
            content: "用户偏好 Swift 5.9",
            type: .preference,
            keywords: ["swift", "preference"]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath), "appendMemory 应通过 PlatformFileSystem 创建文件")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(content.contains("用户偏好 Swift 5.9"), "文件内容应包含记忆内容")

        // 测试完成后清理
        try? FileManager.default.removeItem(atPath: filePath)
    }

    // MARK: - 3. PlatformFileSystem appendFile

    func test_platformFileSystem_appendFile() async throws {
        let filePath = (tempRoot as NSString).appendingPathComponent("append.txt")

        try await parentPFS.writeFile(at: filePath, content: "first line\n")
        try await parentPFS.appendFile(at: filePath, content: "second line\n")

        let content = try parentPFS.readFile(at: filePath)
        XCTAssertEqual(content, "first line\nsecond line\n", "appendFile 应追加内容")
    }

    func test_fileManagerStrategy_appendFile_createsFile() async throws {
        let strategy = FileManagerFileSystemStrategy()
        let filePath = (tempRoot as NSString).appendingPathComponent("strategy_append.txt")

        try await strategy.appendFile(at: filePath, content: "line 1\n")
        try await strategy.appendFile(at: filePath, content: "line 2\n")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "line 1\nline 2\n")
    }

    func test_posixSpawnStrategy_appendFile_fallbackToFileManager() async throws {
        let strategy = PosixSpawnFileSystemStrategy()
        let filePath = (tempRoot as NSString).appendingPathComponent("posix_append.txt")

        try await strategy.appendFile(at: filePath, content: "posix fallback line\n")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "posix fallback line\n")
    }

    func test_iosSystemStrategy_appendFile_fallbackToFileManager() async throws {
        let strategy = IOSSystemFileSystemStrategy()
        let filePath = (tempRoot as NSString).appendingPathComponent("ios_append.txt")

        try await strategy.appendFile(at: filePath, content: "ios fallback line\n")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "ios fallback line\n")
    }

    // MARK: - 4. SkillRegistry getSkill

    func test_skillRegistry_getSkill_returnsSkill() async throws {
        let registry = SkillRegistry()

        // 通过项目级加载技能：创建项目技能目录
        let skillsDir = (tempRoot as NSString).appendingPathComponent(".baize/skills/test-skill")
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
        let skillContent = """
        ---
        name: test-skill
        description: 测试技能
        triggers:
          - test
        priority: 10
        ---

        # 工作流

        1. 执行测试
        """
        try skillContent.write(toFile: (skillsDir as NSString).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        await registry.loadProjectSkills(path: tempRoot)

        let fetched = await registry.getSkill(name: "test-skill")
        XCTAssertNotNil(fetched, "getSkill 应返回已加载技能")
        XCTAssertEqual(fetched?.name, "test-skill")
        XCTAssertEqual(fetched?.source, .project)
    }

    func test_skillRegistry_getSkill_missingSkill_returnsNil() async {
        let registry = SkillRegistry()
        let fetched = await registry.getSkill(name: "nonexistent")
        XCTAssertNil(fetched, "未加载技能应返回 nil")
    }
}
