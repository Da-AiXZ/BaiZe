# 白泽 (Baize) — AI 继承者交接文档

> **给下一位 AI 的话：** 这份文档就是你的"记忆"。读完 ≈ 你跟着我从头干到了这里。
> 严格按文档指示操作，不要自己瞎猜。代码按"改什么 → 改成什么"的格式给出，
> 照抄即可。

---

## 1. 我是谁，我在干什么

### 项目身份
- **名称**：白泽 (Baize) — iOS 本地编程智能体
- **类比**：像 Claude Code / Codex，但跑在 iPad Pro M1 本地
- **运行环境**：iOS 16.6.1，通过 TrollStore 免签安装
- **构建方式**：GitHub Actions CI (macOS 15 runner) → 编译 IPA → ldid fakesign → 下载安装
- **仓库地址**：https://github.com/Da-AiXZ/BaiZe
- **本地路径**：`D:\111\2026-06-17-14-16-26\baize-delivery\`
- **分支**：`main`

### 当前阶段
Phase 2B（构建系统重构）的 CI 调试尾巴 — 只剩下 **3 个 Swift 编译错误** 挡住编译，修完就能出 IPA。

### 已完成的工作流
```
Phase 1: PRD → 架构设计 → 代码实现 → QA 审查 ✅
Phase 2A: 23 个 Warning 全部修复 ✅
Phase 2B: XcodeGen + CI/CD 重写 + GitHub Actions pipeline ✅
Phase 2B CI Debug: 6 轮 CI 修复 (xcpretty/runner/SSH/LaunchScreen/Swift errors) 🔄
                 还剩 3 个错误就能通过 ⬅️ 你就从这里开始
```

---

## 2. 当前任务：修复 3 个 CI 编译错误，让 IPA 编译通过

### 最新 CI 运行状态
- Run ID: `27679970235`
- Commit: `a26e957` — `fix: remaining Swift 5.10 compilation errors for Xcode 16`
- 状态: ❌ 失败 (3 个编译错误)
- 运行环境: macOS 15 + Xcode 16.4，Swift 6 语言模式

### 错误 1/3 — BaizeApp.swift:52 — keychainService 重复初始化

**文件**: `Baize/Baize/App/BaizeApp.swift`
**行号**: 第 13 行和第 52 行
**CI 日志原文**:
```
❌ immutable value 'self.keychainService' may only be initialized once
```

**问题**：第 13 行 `private let keychainService = KeychainService()` 给了默认值，
然后 init() 里第 52 行又 `self.keychainService = keychain` 赋值了一次。
Swift 的 `let` 不允许赋值两次。

**当前代码（第 13 行）**:
```swift
private let keychainService = KeychainService()
```

**改成**:
```swift
private let keychainService: KeychainService
```
去掉 `= KeychainService()` 默认值就行。init() 里已经有合法的赋值了。

---

### 错误 2/3 — ChatView.swift:111 — 缺少 try await

**文件**: `Baize/Baize/Views/Chat/ChatView.swift`
**行号**: 第 111 行
**CI 日志原文**:
```
⚠️ expression is 'async' but is not marked with 'await'; this is an error in the Swift 6 language mode
```

**问题**：AgentLoop 是 actor，`run()` 是 async throws 方法，调用处少了 `try await`。

**当前代码（第 111 行）**:
```swift
let eventStream = agentLoop.run(userMessage: userMessage)
```

**改成**:
```swift
let eventStream = try await agentLoop.run(userMessage: userMessage)
```

---

### 错误 3/3 — ToolRegistry.swift:18 — actor 隔离

**文件**: `Baize/Baize/Agent/ToolRegistry.swift`
**行号**: 第 17-18 行
**CI 日志原文**:
```
⚠️ actor-isolated instance method 'registerDefaultTools(fileSystemService:runtimeExecutor:)' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
```

**问题**：Swift 6 模式下，actor 的 `init()` 被认为是 nonisolated 上下文，
不能在 init 里直接调 actor-isolated 的 `registerDefaultTools()`。

**解法**：把 init 改成静态工厂模式 — 用 static func 构建 tools 字典，init 直接赋值给 `self.tools`。

**当前代码（第 17-18 行）**:
```swift
init(fileSystemService: FileSystemService? = nil, runtimeExecutor: RuntimeExecutor? = nil) {
    registerDefaultTools(fileSystemService: fileSystemService, runtimeExecutor: runtimeExecutor)
}
```

**改成**:
```swift
init(fileSystemService: FileSystemService? = nil, runtimeExecutor: RuntimeExecutor? = nil) {
    self.tools = Self.buildDefaultTools(
        fs: fileSystemService ?? FileSystemService(rootPath: BaizePath.projectRoot),
        rt: runtimeExecutor ?? RuntimeExecutor()
    )
}

/// 静态工厂 — 构建默认工具字典，供 init 使用
/// Swift 6 模式下 actor init 不能直接调 actor-isolated 方法
private static func buildDefaultTools(fs: FileSystemService, rt: RuntimeExecutor) -> [String: Tool] {
    var tools: [String: Tool] = [:]
    // 文件操作工具 (6 个)
    let readFile = ReadFileTool(fileSystemService: fs);    tools[readFile.name] = readFile
    let writeFile = WriteFileTool(fileSystemService: fs);  tools[writeFile.name] = writeFile
    let editFile = EditFileTool(fileSystemService: fs);    tools[editFile.name] = editFile
    let listDir = ListDirectoryTool(fileSystemService: fs); tools[listDir.name] = listDir
    let searchFiles = SearchFilesTool(fileSystemService: fs); tools[searchFiles.name] = searchFiles
    let searchContent = SearchContentTool(fileSystemService: fs); tools[searchContent.name] = searchContent
    // 运行时工具 (3 个)
    let execCmd = ExecuteCommandTool(runtimeExecutor: rt);  tools[execCmd.name] = execCmd
    let runNode = RunNodeTool(runtimeExecutor: rt);         tools[runNode.name] = runNode
    let runPython = RunPythonTool(runtimeExecutor: rt);     tools[runPython.name] = runPython
    return tools
}
```

> 注意：`registerDefaultTools` 原本定义在 ToolRegistry.swift 的第 86 行附近。
> 如果未来不再需要它，可以删除。不过保留也不影响编译（只是不会被调用了）。

---

## 3. 修完 3 个错误后的操作流程

```
1. git add -A
2. git commit -m "fix: final 3 Swift 6 compilation errors (BaizeApp, ChatView, ToolRegistry)"
3. git push origin main
4. 等 CI 2 分钟
5. 如果 CI 通过 → 下载 IPA artifact → 安装到 iPad (TrollStore)
6. 如果 CI 还失败 → 用 gh run view --log-failed 看新的错误
```

---

## 4. CI/CD 管道速查

### 工作流文件
`.github/workflows/build.yml`

### CI 步骤顺序
```
Checkout → Print Xcode version → Install tools (brew ldid xcodegen + gem xcpretty)
→ Cache SPM → Configure git HTTPS → xcodegen generate → Resolve SPM
→ Download Runtime → xcodebuild archive → build-ipa.sh → verify-ipa.sh
→ Upload IPA artifact
```

### 构建关键参数
- Runner: `macos-15` (Xcode 16.x) — 必须用这个，项目格式 77 需要 Xcode 16+
- SDK: `iphoneos` arch: `arm64`
- 签名: ldid fakesign (不是 Apple 证书签名，适合 TrollStore)
- IPA 输出: `output/Baize.ipa`
- 部署目标: iOS 16.0 (但 CI 实际拉到 18.5 因为 SDK 版本)

### 历史 CI 失败记录（全 6 轮，已修复）
1. `xcpretty` 是 gem 不是 brew → 改用 `gem install`
2. macos-14 runner 的 Xcode 15 不认项目格式 77 → 换 `macos-15`
3. ios_system wasm3 子模块用 SSH URL → `git config insteadOf`
4. LaunchScreen.storyboard 编译 -1 错误 → 换成 UILaunchScreen plist
5. 3 个 Swift 5.10 错误 (FocusState/Int16/killpgid) → 已修
6. 更多 Swift 6 错误 (await/actor/conformance) → 大部分已修，剩 3 个

---

## 5. GitHub CLI 使用方法

在 Windows (Git Bash) 上操作 GitHub Actions:

```bash
# 设置 token（用户提供的 PAT）
export GH_TOKEN=<用户会提供自己的 GitHub PAT>

# gh 完整路径
"/c/Program Files/GitHub CLI/gh.exe"

# 查看最近 CI 运行
"/c/Program Files/GitHub CLI/gh.exe" run list --repo Da-AiXZ/BaiZe --limit 5

# 查看失败日志
"/c/Program Files/GitHub CLI/gh.exe" run view <RUN_ID> --repo Da-AiXZ/BaiZe --log-failed

# 关注当前运行
"/c/Program Files/GitHub CLI/gh.exe" run watch <RUN_ID> --repo Da-AiXZ/BaiZe
```

---

## 6. 项目文件结构

```
baize-delivery/
├── .github/workflows/build.yml    ← CI/CD 流水线
├── project.yml                    ← XcodeGen 项目规范
├── scripts/
│   ├── build-ipa.sh               ← 从 xcarchive 打包 IPA + ldid 签名
│   ├── verify-ipa.sh              ← IPA 完整性验证
│   └── download-runtime.sh        ← 下载 node/python 运行时（Phase 2B placeholder）
├── Baize/
│   ├── Baize.xcodeproj/           ← XcodeGen 生成，不提交
│   └── Baize/
│       ├── App/
│       │   └── BaizeApp.swift     ← @main 入口 + DI 容器 ← 错误 1 在这
│       ├── Agent/
│       │   ├── AgentLoop.swift    ← actor 主循环 (user→LLM→tool→result)
│       │   ├── ToolRegistry.swift ← actor 工具注册表 ← 错误 3 在这
│       │   ├── PermissionEngine.swift
│       │   ├── ProjectContext.swift
│       │   ├── ContextManager.swift
│       │   ├── ConversationStore.swift
│       │   ├── Message.swift
│       │   └── ...
│       ├── Views/
│       │   ├── Chat/
│       │   │   ├── ChatView.swift      ← 错误 2 在这
│       │   │   ├── ChatInputView.swift
│       │   │   ├── MessageBubble.swift
│       │   │   └── ToolCallView.swift
│       │   ├── Editor/
│       │   ├── Settings/
│       │   └── ...
│       ├── Infrastructure/
│       │   ├── RuntimeExecutor.swift   ← 进程执行 (posix_spawn)
│       │   ├── MonacoBridge.swift      ← WKWebView + Monaco Editor
│       │   ├── APIGateway.swift
│       │   ├── FileSystemService.swift
│       │   ├── KeychainService.swift
│       │   └── SSEStream.swift
│       ├── Tools/
│       │   ├── ReadFileTool.swift
│       │   ├── WriteFileTool.swift
│       │   ├── EditFileTool.swift
│       │   ├── ListDirectoryTool.swift
│       │   ├── SearchFilesTool.swift
│       │   ├── SearchContentTool.swift
│       │   ├── ExecuteCommandTool.swift
│       │   ├── RunNodeTool.swift
│       │   └── RunPythonTool.swift
│       ├── Models/
│       │   └── AppState.swift
│       └── Utils/
├── docs/
│   ├── baize-prd.md                ← Phase 1 PRD
│   ├── baize-architecture.md       ← Phase 1 架构设计
│   ├── baize-qa-report.md          ← Phase 1 QA 报告
│   ├── baize-phase2-plan.md        ← Phase 2 规划
│   └── analysis/                   ← 8 份深度分析报告
└── BAIZE_HANDOFF.md                ← 你在读的这个文件
```

---

## 7. 核心架构速览

### 三层架构
```
UI (SwiftUI) → Business (Agent Services) → Infrastructure (Platform)
```

### Agent Loop 流程
```
用户输入 → AgentLoop(actor) → LLM reasoning (SSE流式)
  → tool_call ← → ToolRegistry → 执行 → 结果
  → 循环直到 LLM 返回 finish
```

### 并发模型（全部 Swift Actor）
- `AgentLoop`: actor — 主循环，一次只处理一条消息
- `ToolRegistry`: actor — 工具注册/查找
- `APIGateway`: actor — LLM API 调用
- `PermissionEngine`: actor — 权限决策
- `ConversationStore`: actor — 对话持久化

### 9 个内置工具
| 工具 | 用途 |
|------|------|
| ReadFile | 读取文件 |
| WriteFile | 写入文件 |
| EditFile | 精确编辑文件 |
| ListDirectory | 列出目录 |
| SearchFiles | 按名称搜索文件 |
| SearchContent | 按内容搜索文件 |
| ExecuteCommand | 执行 Shell 命令 |
| RunNode | 运行 Node.js |
| RunPython | 运行 Python |

### iOS 特有约束
- 禁止 `fork()` — 用 `posix_spawn` 替代
- 禁止 JIT — Node.js 用 `--jitless` 模式
- TrollStore 分发 — 需要 `platform-application` entitlement
- spawned binary 必须在 App Bundle 内
- 无沙盒 — TrollStore 授予完整文件系统访问

---

## 8. 关键技术决策（已完成的重要选择）

| 编号 | 决策 | 理由 |
|------|------|------|
| Q1 | 嵌入主进程（不用 App Extension） | iOS 不支持 child_process，白泽用 posix_spawn |
| Q2 | Monaco Editor via WKWebView | 参考 CodeApp 架构，用 GCDWebServer 启动本地服务 |
| Q3 | Python 最小集 + 按需 pip | Phase 1 只带最小 Python，纯 pip 包可运行时装 |
| Q4 | `/var/mobile/Documents/Baize/` 默认路径 | iOS 标准文档目录 |
| Q5 | Phase 1 仅 OpenAI API | Phase 2C 加 Anthropic + OpenRouter |
| Q6 | Phase 1 简单弹窗权限 | Phase 2 升级为 ABAC 细粒度权限 |
| 2B | XcodeGen 替代 SPM library target | 统一管理依赖，CI 友好 |

---

## 9. Phase 路线图（完成后继任务）

| Phase | 内容 | 状态 |
|-------|------|------|
| 1 | PRD + 架构 + 代码 + QA | ✅ 完成 |
| 2A | 修复 23 个 Warning | ✅ 完成 |
| 2B | 构建系统重构 + CI + IPA | 🔄 CI 调试中（你就是这步） |
| 2C | 多模型支持 (OpenAI/Anthropic/OpenRouter) | ⏳ 待开始 |
| 2D | Monaco Editor 真实集成 (GCDWebServer + npm) | ⏳ 待开始 |

---

## 10. 常见坑和注意事项

1. **`gh` CLI 路径**: Windows 下是 `"/c/Program Files/GitHub CLI/gh.exe"`，不是 `gh`
2. **SSH 子模块**: ios_system 的 wasm3 子模块用 SSH URL，需要 `git config --global url."https://github.com/".insteadOf "git@github.com:"`
3. **xcpretty 是 Ruby Gem**: 不是 Homebrew formula，用 `gem install`
4. **macOS Runner**: 必须是 `macos-15`（Xcode 16），`macos-14` 的 Xcode 15 不认 project format 77
5. **Swift 6 严格模式**: Xcode 16 默认启用 — actor 隔离规则更严，所有 async 调用必须显式 `await`
6. **`let` vs `var`**: 已经初始化的 `let` 属性不能再在 init 里赋值
7. **CRLF 警告**: 不用管，是 Windows Git 的自动换行转换
8. **Information.plist 的 UILaunchScreen**: iOS 14+ 用字典替代 storyboard，不需要 LaunchScreen.storyboard 文件
9. **IPA 签名**: 用 `ldid` 而不是 Apple 证书 — 对 `.app/AppName` 可执行文件签名，不是整个 `.ipa`
10. **POSIX_SPAWN_SETPGROUP**: macOS/iOS 上是 `Int16` 类型，需要显式 cast: `Int16(POSIX_SPAWN_SETPGROUP)`

---

## 11. 快速参考命令

```bash
# 进入项目
cd /d/111/2026-06-17-14-16-26/baize-delivery

# 查看状态
git status
git log --oneline -5

# 推送到 GitHub
git push origin main

# 查看 CI
"/c/Program Files/GitHub CLI/gh.exe" run list --repo Da-AiXZ/BaiZe --limit 3

# 查看失败日志
"/c/Program Files/GitHub CLI/gh.exe" run view <RUN_ID> --repo Da-AiXZ/BaiZe --log-failed

# 编译失败时只看错误行
"/c/Program Files/GitHub CLI/gh.exe" run view <RUN_ID> --repo Da-AiXZ/BaiZe --log-failed 2>&1 | grep -E "❌|⚠️"
```

---

## 12. 前任 AI 的总结

```
我（上一位 AI）的工作：
- Phase 1 全部：PRD → 架构设计 → 代码实现 → QA 审查
- Phase 2A：修复了全部 23 个 Warning
- Phase 2B：重建了整个构建系统（XcodeGen + project.yml + CI/CD + IPA 打包脚本）
- Phase 2B CI 调试：修了 6 轮构建失败

你（接手的 AI）只需要：
1. 改上面标注的 3 个文件（改什么→改成什么 都写清楚了）
2. git commit && git push
3. 等 CI 通过
4. 下载 IPA artifact

3 个错误，10 分钟搞定。祝顺利 🔧
```

---

*生成时间: 2026-06-17 | 项目: 白泽 Baize iOS 本地编程智能体 | 阶段: Phase 2B CI 调试*
