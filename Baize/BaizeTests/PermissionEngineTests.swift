import XCTest
@testable import Baize

/// T04 Phase: 权限引擎统一单元测试
///
/// 验证点：
/// 1. PermissionEngine 是单一权限门（AgentLoop 不再独立拦截 PlanMode）
/// 2. PermissionMode 支持 5 种模式
/// 3. PlanMode 硬拦截不受 bypass 影响
/// 4. bypass 模式下写操作自动允许
/// 5. dontAsk 模式将 ask 转 deny
/// 6. Session Approval（"本次会话不再询问"）生效
final class PermissionEngineTests: XCTestCase {

    private var fileSystemService: FileSystemService!
    private var runtimeExecutor: RuntimeExecutor!
    private var permissionEngine: PermissionEngine!
    private var toolRegistry: ToolRegistry!

    override func setUp() async throws {
        try await super.setUp()
        fileSystemService = FileSystemService(rootPath: BaizePath.projectRoot)
        runtimeExecutor = RuntimeExecutor()
        permissionEngine = PermissionEngine()
        toolRegistry = ToolRegistry(
            fileSystemService: fileSystemService,
            runtimeExecutor: runtimeExecutor
        )
        await permissionEngine.setToolRegistry(toolRegistry)
    }

    override func tearDown() async throws {
        await permissionEngine.clearSessionApprovals()
        permissionEngine = nil
        toolRegistry = nil
        runtimeExecutor = nil
        fileSystemService = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext(planModeState: PlanModeState? = nil) -> ToolExecutionContext {
        ToolExecutionContext(
            projectPath: BaizePath.projectRoot,
            fileSystemService: fileSystemService,
            runtimeExecutor: runtimeExecutor,
            permissionEngine: permissionEngine,
            planModeState: planModeState
        )
    }

    private func toolCall(name: String, arguments: [String: Any]) -> ToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [])
        let argumentsString = String(data: data, encoding: .utf8)!
        return ToolCall(id: UUID().uuidString, name: name, arguments: argumentsString)
    }

    private func evaluate(
        _ toolCall: ToolCall,
        mode: PermissionMode,
        planModeState: PlanModeState? = nil
    ) async -> PermissionDecision {
        await permissionEngine.setMode(mode)
        let context = makeContext(planModeState: planModeState)
        return await permissionEngine.evaluate(toolCall: toolCall, context: context)
    }

    // MARK: - 1. default 模式下 readOnly 工具自动 allow

    func test_defaultMode_readOnlyTool_allow() async {
        let call = toolCall(name: "read_file", arguments: ["path": "README.md"])
        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .allow, "default 模式下 read_file 应自动 allow")
    }

    // MARK: - 2. default 模式下 destructive 工具 ask

    func test_defaultMode_destructiveTool_ask() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "new_file.txt",
            "content": "hello"
        ])
        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .ask, "default 模式下 write_file 应 ask")
    }

    // MARK: - 3. default 模式下删除 BAIZE.md 直接 deny

    func test_defaultMode_deleteBaizeConfig_deny() async {
        let call = toolCall(name: "delete_file", arguments: ["path": "BAIZE.md"])
        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .deny, "删除 BAIZE.md 应直接 deny")
    }

    // MARK: - 4. plan 模式下写工具 deny

    func test_planMode_writeTool_deny() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "new_file.txt",
            "content": "hello"
        ])
        let decision = await evaluate(call, mode: .plan)
        XCTAssertEqual(decision.effect, .deny, "plan 模式下 write_file 应 deny")
    }

    // MARK: - 5. bypass 模式下写工具 allow

    func test_bypassMode_writeTool_allow() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "new_file.txt",
            "content": "hello"
        ])
        let decision = await evaluate(call, mode: .bypass)
        XCTAssertEqual(decision.effect, .allow, "bypass 模式下 write_file 应 allow")
    }

    // MARK: - 6. bypass + plan 模式下写工具 deny（PlanMode 免疫 bypass）

    func test_bypassAndPlanMode_writeTool_deny() async {
        let planModeState = PlanModeState()
        await planModeState.enter()

        let call = toolCall(name: "write_file", arguments: [
            "path": "new_file.txt",
            "content": "hello"
        ])
        let decision = await evaluate(call, mode: .bypass, planModeState: planModeState)
        XCTAssertEqual(decision.effect, .deny, "bypass + plan 模式下 write_file 仍应 deny")
    }

    // MARK: - 7. dontAsk 模式下 ask 转 deny

    func test_dontAskMode_writeTool_deny() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "new_file.txt",
            "content": "hello"
        ])
        let decision = await evaluate(call, mode: .dontAsk)
        XCTAssertEqual(decision.effect, .deny, "dontAsk 模式下 write_file 应 deny")
    }

    // MARK: - 8. session approval 后工具 allow

    func test_sessionApproval_grantedTool_allow() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "/var/mobile/Documents/Baize/new_file.txt",
            "content": "hello"
        ])
        await permissionEngine.grantSessionApproval(forTool: "write_file", operation: "/var/mobile/Documents/Baize/new_file.txt")

        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .allow, "session approval 后 write_file 应 allow")
    }

    // MARK: - 9. ToolRegistry.isEnabled(.plan) 对非 readOnly 工具返回 false

    func test_toolRegistry_planMode_nonReadOnly_disabled() async {
        let enabled = await toolRegistry.isEnabled(toolName: "read_file", mode: .plan)
        XCTAssertTrue(enabled, "plan 模式下 read_file 应启用")

        let disabled = await toolRegistry.isEnabled(toolName: "write_file", mode: .plan)
        XCTAssertFalse(disabled, "plan 模式下 write_file 应禁用")
    }

    // MARK: - 10. acceptEdits 模式下文件编辑 allow、命令执行仍 ask

    func test_acceptEditsMode_editFile_allow() async {
        let call = toolCall(name: "edit_file", arguments: [
            "path": "README.md",
            "old_string": "hello",
            "new_string": "world"
        ])
        let decision = await evaluate(call, mode: .acceptEdits)
        XCTAssertEqual(decision.effect, .allow, "acceptEdits 模式下 edit_file 应 allow")
    }

    func test_acceptEditsMode_executeCommand_ask() async {
        let call = toolCall(name: "execute_command", arguments: ["command": "ls"])
        let decision = await evaluate(call, mode: .acceptEdits)
        XCTAssertEqual(decision.effect, .ask, "acceptEdits 模式下 execute_command 仍应 ask")
    }

    // MARK: - 11. plan 模式下 readOnly 工具仍允许

    func test_planMode_readOnlyTool_allow() async {
        let call = toolCall(name: "read_file", arguments: ["path": "README.md"])
        let decision = await evaluate(call, mode: .plan)
        XCTAssertEqual(decision.effect, .allow, "plan 模式下 read_file 仍应 allow")
    }

    // MARK: - 12. bypass + plan 模式下 readOnly 工具仍允许

    func test_bypassAndPlanMode_readOnlyTool_allow() async {
        let planModeState = PlanModeState()
        await planModeState.enter()

        let call = toolCall(name: "read_file", arguments: ["path": "README.md"])
        let decision = await evaluate(call, mode: .bypass, planModeState: planModeState)
        XCTAssertEqual(decision.effect, .allow, "bypass + plan 模式下 read_file 仍应 allow")
    }

    // MARK: - 13. bypass 模式下 alwaysDeny 仍生效

    func test_bypassMode_alwaysDeniedCommand_deny() async {
        let call = toolCall(name: "execute_command", arguments: ["command": "rm -rf /"])
        let decision = await evaluate(call, mode: .bypass)
        XCTAssertEqual(decision.effect, .deny, "bypass 模式下 rm -rf / 仍应 deny")
    }

    // MARK: - 14. 未知工具在 default 模式下 ask

    func test_defaultMode_unknownTool_ask() async {
        let call = toolCall(name: "unknown_tool", arguments: [:])
        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .ask, "default 模式下未知工具应 ask")
    }

    // MARK: - 15. session approval 通配 key（仅 toolName）生效

    func test_sessionApproval_wildcard_allow() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "/var/mobile/Documents/Baize/another.txt",
            "content": "hello"
        ])
        await permissionEngine.grantSessionApproval(forTool: "write_file")

        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .allow, "session approval 通配 toolName 后应 allow")
    }

    // MARK: - 16. clearSessionApprovals 清除所有授权

    func test_clearSessionApprovals_revokesGrants() async {
        let call = toolCall(name: "write_file", arguments: [
            "path": "/var/mobile/Documents/Baize/file.txt",
            "content": "hello"
        ])
        await permissionEngine.grantSessionApproval(forTool: "write_file")
        await permissionEngine.clearSessionApprovals()

        let decision = await evaluate(call, mode: .default)
        XCTAssertEqual(decision.effect, .ask, "clearSessionApprovals 后应恢复 ask")
    }

    // MARK: - 17. setMode / getMode 状态同步

    func test_setMode_updatesGetMode() async {
        await permissionEngine.setMode(.plan)
        let mode = await permissionEngine.getMode()
        XCTAssertEqual(mode, .plan, "setMode 后 getMode 应返回 plan")
    }
}
