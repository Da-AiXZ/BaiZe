# 白泽 (Baize) — 全量代码审查问题清单

> **审查时间**: 2026-06-23
> **审查范围**: 131 源文件 + 7 测试 + 3 配置 = 141 文件全部 Read 读完
> **审查方式**: QA 严过关读模块 1-6+8（100 文件），工程师寇豆码读模块 7（31 View 文件）
> **总行数**: 32120 行源码 + 2550 行测试
> **发现问题**: 57 个（P0×3, P1×6, P2×11, P3×37）

---

## 严重级别定义

| 级别 | 含义 |
|------|------|
| P0-崩溃 | 会导致 App 启动崩溃或运行时必崩 |
| P0-功能不可用 | 导致核心功能完全不能用 |
| P1-功能异常 | 功能部分失效或行为不正确 |
| P2-潜在风险 | 可能在特定条件触发问题 |
| P3-代码质量 | 不影响运行但应改进 |

---

## P0 问题（3 个，必须修复才能用）

### P0-1 [崩溃] FileSystemService.runSync() 主线程阻塞

- **文件**: `Baize/Baize/Infrastructure/FileSystemService.swift:170-191`
- **问题**: `runSync()` 使用 `DispatchSemaphore.wait()` 阻塞调用线程等待 `Task.detached` 完成。EditorState 的 `closeTab()`、`switchToTab()`、`refreshFile()` 等方法在 `@MainActor` 上同步调用 `fileSystemService.readFile()`，这会导致主线程被阻塞。如果 PlatformFileSystem actor 正忙于处理其他请求，主线程会长时间冻结，导致 UI 卡死或被 watchdog 杀死。
- **根因**: v15 重构引入 PlatformFileSystem actor 后，FileSystemService 作为同步包装层用 semaphore 桥接 async actor 调用，但忽略了主线程阻塞风险。
- **建议**: 将 EditorState 的文件操作改为 async，或使用缓存避免同步等待 actor。
- **影响范围**: 所有通过 FileSystemService 同步访问文件的操作（编辑器、文件浏览器、搜索）。

### P0-2 [功能不可用] GitShellService 依赖空 git 二进制

- **文件**: `Baize/Baize/Services/GitShellService.swift:155-158`、`Baize/Baize/Utils/Constants.swift:633`
- **问题**: `BaizeBinary.gitBinaryPath` 使用 `Bundle.main.path(forResource:...)` 查找 git 二进制，找不到则回退到相对路径 `"binaries/git"`（无法解析）。`GitShellService.ensureGitBinaryExists()` 会在二进制不存在时抛出错误，导致 fetch/push/pull/clone 全部失败。
- **根因**: v15 架构师选择 shell out git 二进制方案，但 `Baize/Baize/Resources/binaries/git` 是 0 字节占位文件，从未替换为真实二进制。编译 iOS arm64 静态 git 需要 macOS + Xcode toolchain，用户环境无 Mac。
- **建议**: 两个选项：
  1. 改回 libgit2 + `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, cacert.pem, nil)` 设置 CA 证书路径（推荐，改动小，无需编译 git）
  2. 在 CI 中加编译 git 二进制的 step（复杂，CI 时间 +15-20 分钟，可能失败）
- **影响范围**: Git HTTPS 远程操作（clone/fetch/push/pull）100% 失败。本地 Git 操作（add/commit/log/branch）不受影响，走 libgit2。

### P0-3 [功能不可用] ProjectContext.updateRootPath() 破坏共享实例

- **文件**: `Baize/Baize/Agent/ProjectContext.swift:57`
- **问题**: `updateRootPath` 方法创建了新的 `FileSystemService(rootPath: path)` 实例，而非使用 `fileSystemService.updateRootPath(path)`。这导致 ProjectContext 内部的 FileSystemService 与 BaizeApp 注入的共享实例脱钩。
- **根因**: v15 重构时遗漏，FileSystemService 应该有 `updateRootPath` 方法但 ProjectContext 没调用它。
- **建议**: 改为 `fileSystemService.updateRootPath(path)` 或添加 `setRootPath(path)` 方法。
- **影响范围**: 切换项目路径时，ProjectContext 内部文件操作（读取 BAIZE.md 等）与新项目路径脱节。

---

## P1 问题（6 个，功能异常）

### P1-1 AgentLoop 工具调用执行顺序不确定

- **文件**: `Baize/Baize/Agent/AgentLoop.swift:330`
- **问题**: `for (id, arguments) in currentToolCallArguments` 遍历 Dictionary，执行顺序不确定。如果 LLM 返回多个工具调用且有依赖关系（如先 write_file 再 read_file），可能因执行顺序错误导致失败。
- **建议**: 使用 `accumulatedToolCalls` 数组（有序）替代 Dictionary 遍历。

### P1-2 RuntimeExecutor.executeCommand exitCode 恒为 0

- **文件**: `Baize/Baize/Infrastructure/RuntimeExecutor.swift:306`
- **问题**: ios_popen 路径的 exitCode 恒为 0（iOS 不支持 pclose 获取退出码）。AgentLoop 根据 `result.isError` 判断失败，但如果 ios_popen 命令失败但 exitCode 为 0 且无 stderr，`isError` 为 false，失败计数器不会递增。
- **建议**: 尽量依赖 NativeCommands 的 exitCode，或在 ios_popen 返回空输出时标记为可疑。

### P1-3 GitViewModel 每次刷新创建新 KeychainService

- **文件**: `Baize/Baize/ViewModels/GitViewModel.swift:130,136,142`
- **问题**: `refreshStatus()` 中三次创建 `KeychainService()` 实例。虽然 KeychainService 是 struct，但每次创建都会初始化 KeychainAccess 实例，造成不必要开销。
- **建议**: 从 AppState 获取共享的 KeychainService 实例。

### P1-4 MemoryStore.writeViaFileManager() 强制解包

- **文件**: `Baize/Baize/Agent/Memory/MemoryStore.swift:233`
- **问题**: `handle.write(lineToWrite.data(using: .utf8)!)` — 强制解包 `data(using:)`。虽然 UTF-8 编码理论上不会失败，但如果字符串包含某些异常 Unicode 标量，可能崩溃。
- **建议**: 使用 `guard let data = content.data(using: .utf8) else { throw ... }`。

### P1-5 PlatformFileSystemStrategy.swift 强制解包

- **文件**: `Baize/Baize/Infrastructure/PlatformFileSystemStrategy.swift:67`
- **问题**: 同 P1-4，`data(using: .utf8)!` 强制解包。
- **建议**: 同上，改用 guard let。

### P1-6 PythonSpawnStrategy workingDir 未设置

- **文件**: `Baize/Baize/Infrastructure/RuntimeStrategy.swift:224-228`
- **问题**: `workingDirCString` 被分配后立即 free，从未传给 `posix_spawn`。子进程在默认目录运行而非指定的工作目录。不过此策略在生产中不使用（BaizeApp 使用 PythonEmbeddingStrategy），影响有限。
- **建议**: 如果保留此策略，需通过 `posix_spawn_file_actions_addchdir` 或 `chdir` 设置工作目录。

---

## P2 问题（11 个，潜在风险）

### P2-1 PlanModeState.exit() continuation 泄漏

- **文件**: `Baize/Baize/Agent/PlanMode/PlanModeState.swift:82-84`
- **问题**: `exit(plan:)` 使用 `withCheckedContinuation` 挂起等待 `approve()` 或 `reject()`。如果用户关闭 App 或 AgentLoop 被取消而未调用 approve/reject，continuation 永远不会被 resume，导致 Task 泄漏。
- **建议**: 添加 `withTaskCancellationHandler` 或在 `reset()` 中 resume continuation。

### P2-2 PosixSpawnFileSystemStrategy 无超时

- **文件**: `Baize/Baize/Infrastructure/PlatformFileSystemStrategy.swift:264-292`
- **问题**: `runPosixSpawn` 中的 `waitpid(pid, &status, 0)` 是阻塞调用，无超时。如果 spawned 进程挂起（如 git 等待网络），调用线程（可能通过 FileSystemService.runSync 阻塞主线程）会无限期阻塞。
- **建议**: 使用 `waitpid` + `alarm` 或 `WNOHANG` 轮询 + 超时。

### P2-3 KeychainService UserDefaults fallback 明文存 API Key

- **文件**: `Baize/Baize/Infrastructure/KeychainService.swift:36-41`
- **问题**: Keychain 失败时将 API Key 明文存储到 UserDefaults。在 TrollStore no-sandbox 环境下，其他 App 可能读取 UserDefaults。
- **建议**: 对 UserDefaults fallback 的值进行简单加密（如 Base64 + XOR），或只在 Keychain 完全不可用时才启用 fallback。

### P2-4 BaizeApp.resolveWorkingDirectory() 路径不一致

- **文件**: `Baize/Baize/App/BaizeApp.swift:256,276`
- **问题**: TrollStore 路径返回 `trollStorePath`（无尾斜杠），sandbox 路径返回 `sandboxRoot + "/"`（有尾斜杠）。路径拼接时可能导致双斜杠或缺少斜杠。
- **建议**: 统一路径格式，都在末尾加 `/` 或都不加。

### P2-5 MCPServerConnection 使用 NSLock 保护 requestId

- **文件**: `Baize/Baize/Agent/MCP/MCPToolExecutor.swift:93`
- **问题**: 在 `@unchecked Sendable` class 中使用 NSLock 保护 `requestId` 自增。这在 async 上下文中是安全的，但如果 `sendRequest` 被并发调用，多个 HTTP 请求可能交叉，增加调试难度。
- **建议**: 可接受，但建议用 actor 替代。

### P2-6 SSEStream 错误体逐字节构造 Character

- **文件**: `Baize/Baize/Infrastructure/SSEStream.swift:41`
- **问题**: `errorBody.append(Character(UnicodeScalar(byte)))` — 逐字节构造 Character，对多字节 UTF-8 序列会产生乱码。不影响功能但错误信息可能不可读。
- **建议**: 用缓冲区累积字节后一次性解码。

### P2-7 AgentLoop 上下文压缩后 userQuery 重复注入记忆

- **文件**: `Baize/Baize/Agent/AgentLoop.swift:215`
- **问题**: `buildContext` 每次循环迭代都传入 `userQuery`，导致每轮都执行记忆检索。这在长对话中会产生不必要的 LLM 调用开销（虽然记忆检索本身不调 LLM）。
- **建议**: 只在首次或压缩后注入记忆。

### P2-8 ChatInputView detectCommandOrSkill Task 竞态

- **文件**: `Baize/Baize/Views/Chat/ChatInputView.swift:162-184`
- **问题**: `detectCommandOrSkill` 中创建 `Task { @MainActor in ... }` 未存储、未取消。用户快速输入时多个 Task 并发执行 `await registry.searchCommands(prefix:)`，先启动的 Task 可能在后启动的 Task 之后完成，导致 `commandSuggestions` 被旧的搜索结果覆盖。缺少 debounce/cancel 机制（对比 SessionListView 的 `searchDebounceTask` 有正确实现）。
- **建议**: 参照 SessionListView 的 `searchDebounceTask` 模式，存储 Task 并在新输入时 cancel。

### P2-9 ChatInputView skillSuggestion Task 竞态

- **文件**: `Baize/Baize/Views/Chat/ChatInputView.swift:189-195`
- **问题**: 同 P2-8，`matchSkill` 的 Task 也有竞态条件，`skillSuggestion` 可能被旧结果覆盖。
- **建议**: 同 P2-8。

### P2-10 TerminalViewModel ios_popen 取消后仍后台运行

- **文件**: `Baize/Baize/Views/Terminal/TerminalViewModel.swift:57-58,144-148`
- **问题**: `isCancelled` 标志仅忽略输出，ios_popen 进程仍在后台运行直到完成。如果用户快速执行多条命令，可能有多个 ios_popen 进程同时运行（通过串行队列 `executeQueue` 序列化，但前一个命令可能还在执行）。
- **建议**: 可接受的设计权衡，但应在 UI 上提示用户"上一个命令仍在后台执行"。

### P2-11 ChatView agentTask 生命周期管理

- **文件**: `Baize/Baize/Views/Chat/ChatView.swift:13,28`
- **问题**: `@State private var agentLoop: AgentLoop?` 和 `@State private var agentTask: Task<Void, Never>?` 存储在 View 的 @State 中。如果用户切换会话或 View 被重建，旧的 agentTask 可能未被取消。代码中有 `agentGeneration` 机制来丢弃旧 loop 的事件，但如果 agentTask 未被显式取消，AgentLoop 会继续在后台运行消耗 API token。
- **建议**: 确保在 `restoreSession` 和 `startNewSession` 时取消旧的 agentTask。

---

## P3 问题（37 个，代码质量）

### 强制解包（2 处，实际安全但应改）
1. `Views/Chat/ToolCallView.swift:180` — `arguments[key]!` 强制解包（key 来自字典迭代，实际安全）
2. `Views/Dialogs/PermissionDialog.swift:114` — `arguments[key]!` 强制解包（同上）

### Task 未存储/未取消（25 处，fire-and-forget 模式）
3. `Views/Chat/SessionListView.swift:305` — `performExport` 中 Task 未存储，同步 I/O 在 MainActor 上
4. `Views/Dashboard/DashboardView.swift:37,66,73` — 3 个 Task 未存储
5. `Views/Dashboard/NewProjectWizard.swift:108,272` — 2 个 Task 未存储（创建过程中 dismiss 无法取消）
6. `Views/Git/GitDiffView.swift:124` — Task 未存储
7. `Views/Git/GitLogView.swift:39,56,60,264,354` — 5 个 Task 未存储
8. `Views/Git/GitStatusView.swift:19,40` — 2 个 Task 未存储
9. `Views/Settings/GitSettingsView.swift:249,253,282` — 3 个 Task 未存储
10. `Views/Settings/MemorySettingsView.swift:60,70` — 2 个 Task 未存储
11. `Views/Settings/ModelSettingsView.swift:342,359` — 2 个 Task 未存储
12. `Views/Settings/PermissionSettingsView.swift:68,86` — 2 个 Task 未存储
13. `Views/Settings/SkillsManagerView.swift:131` — Task 未存储
14. `Views/Sidebar/FileSearchView.swift:80` — Task 未存储，同步搜索在 MainActor 上可能阻塞 UI

### 错误处理（6 处）
15. `Views/Settings/APIKeySettingsView.swift:140,151,160,177,178,189,215,228,229,238,249` — 6 处 catch 块为空（`// Error handling`），错误被静默吞没，用户无反馈
16. `Models/AppState.swift:464` — `(path as NSString).deletingLastPathComponent.isEmpty` 永远不为空，"Baize" fallback 永远不生效

### 死代码/未使用（2 处）
17. `Models/EditorState.swift:115-117` — `if let bridge = monacoBridge { }` 空代码块
18. `Infrastructure/APIGateway.swift:38` — `private let sseStream = SSEStream()` 创建但从未使用

### 性能/竞态（2 处）
19. `ViewModels/GitViewModel.swift:782-785` — 多次快速调用 `showSuccessMessage` 会创建多个 Task，可能提前隐藏后续成功提示
20. `Views/Sidebar/FileExplorerView.swift:16-23` — `fileSystemService` computed property 每次 nil 时创建新实例
21. `Views/Editor/EditorContainerView.swift:42,61,88` — fallback FileSystemService 创建（防御性代码，但每次创建新实例）

### UI 一致性（1 处）
22. `Views/ContentView.swift:60-65` — 竖屏 TabView 的 Git Tab 实际显示 WorkbenchSidebar，Tab 图标是 Git 但内容是工作台

### 类型/协议（1 处）
23. `Views/Chat/ChatModels.swift:6` — `DisplayMessage` 缺少 `Equatable`，SwiftUI ForEach 可能不必要重绘

### 路径/配置（1 处）
24. `Baize/Baize/Utils/Constants.swift` — `BaizeBinary` 路径常量在二进制缺失时回退到相对路径 `"binaries/git"`，无法解析为真实路径

### 架构决策遗留（1 处）
25. `Baize/Baize/Services/GitService.swift:949` — 注释提到 v15 之前用 "certificate_check 回调接受任何 TLS 证书"（MITM 漏洞），v15 改成 shell out git 二进制但 git 二进制是空的。需要决策：方案 A（CI 编译 git）还是方案 B（改回 libgit2 + CA 路径）

---

## 修复优先级建议

### 第一批（必须修，影响核心可用性）
1. P0-2 GitShellService 空 git 二进制 — 决策方案 A 或 B
2. P0-1 FileSystemService 主线程阻塞
3. P0-3 ProjectContext 破坏共享实例

### 第二批（影响体验正确性）
4. P1-1 AgentLoop 工具调用顺序
5. P1-2 exitCode 恒 0
6. P1-4/5 强制解包
7. P2-8/9 ChatInputView 竞态

### 第三批（安全加固）
8. P2-3 KeychainService 明文存 API Key
9. P2-1 PlanModeState continuation 泄漏
10. P2-2 PosixSpawn 无超时

### 第四批（代码质量，不阻塞）
11. P3 全部 37 个问题

---

## 附录：审查覆盖范围

| 模块 | 文件数 | 已读 | 审查人 |
|------|--------|------|--------|
| 1. App/Models/Utils/ViewModels | 9 | 9 | QA 严过关 |
| 2. Agent Core | 11 | 11 | QA 严过关 |
| 3. Agent Sub-modules | 23 | 23 | QA 严过关 |
| 4. Infrastructure | 18 | 18 | QA 严过关 |
| 5. Services | 8 | 8 | QA 严过关 |
| 6. Tools | 23 | 23 | QA 严过关 |
| 7. Views | 39 | 39 | 工程师寇豆码（31）+ QA 严过关（8） |
| 8. Tests + Config | 7+3 | 7+3 | QA 严过关 |
| **总计** | **141** | **141** | |

所有文件均用 Read 工具逐文件读取，不允许 Grep 跳过。
