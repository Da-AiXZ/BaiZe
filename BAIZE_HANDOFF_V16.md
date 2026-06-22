# 白泽 (Baize) — AI 继承者交接文档 v16

> **给下一位 AI 的话**：v15 架构重构已完成。不要再 patch 旧 Bug，直接进入验证、补全、编译/真机阶段。
> **生成时间**: 2026-06-23 04:08 | **版本**: v16
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 完成 v15 架构重构 T00–T05，所有 QA 验证 IS_PASS YES

---

## 0. TL;DR

1. **项目位置**: `D:\2\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe（分支 `main`）
3. **最新 commit**: `c2697d8 fix(t05): MemoryStore baseDir path`
4. **重构状态**: ✅ v15 六模块架构重构全部完成
5. **测试状态**: 4 个新增测试文件已推送，覆盖 35+ 边界用例（Windows 环境静态走查，未实际运行 xcodebuild）
6. **积分警告**: 用户积分已耗尽。后续任务优先做编译修复和真机验证，每改一次就 commit+push

---

## 1. 你接手时项目的完整状态

v15 重构把白泽从“39 个 Bug 反复 patch”的状态改为新架构。六大核心问题已各自解决：

| 原问题 | 根因 | 解决方案 | 关键文件 |
|--------|------|----------|----------|
| B01 创建目录失败 | FileManager/posix_spawn/ios_system 三套机制混用 | `PlatformFileSystem` 统一入口 + 3 种 `FileSystemStrategy` | `Infrastructure/PlatformFileSystem.swift`, `PlatformFileSystemStrategy.swift` |
| B02 git fetch 0 字节 | libgit2+OpenSSL 在 iOS 访问不了 Keychain CA | 打包静态 git 二进制 + `posix_spawn` + bundled `cacert.pem` | `Services/GitShellService.swift` |
| B03 bypass 不生效 | PermissionEngine / PlanMode / AgentLoop 三层各自判断 | 统一为 `PermissionEngine` 单一决策点 | `Agent/PermissionEngine.swift`, `Agent/ToolRegistry.swift` |
| B08 subagent 串扰 | 子 Agent 共享父 Agent 状态 | 每个子 Agent 独立 `SubAgentContext` + 独立 `PermissionEngine` + 独立 `ConversationSession` | `Agent/SubAgent/SubAgentContext.swift`, `Agent/SubAgent/AgentTool.swift` |
| Skills 占位 | 只做 prompt 注入，未真正执行 | `SkillExecutor` fork 子 Agent 执行 workflow | `Agent/Skills/SkillExecutor.swift`, `Tools/SkillTool.swift` |
| Memory 目录静默失败 | JSONL 写入前目录未创建，失败被吞 | `MemoryStore` 走 `PlatformFileSystem` + `AgentLoop` stop-hook 触发提取 | `Agent/Memory/MemoryStore.swift`, `Agent/Memory/MemoryExtractor.swift` |

---

## 2. 最新 Commit 历史（必读）

```
c2697d8 fix(t05): MemoryStore baseDir path          ← 最新
8c45091 test(t05): sub-agent isolation, skills, memory
2a7e4b3 refactor(t05): memory platform filesystem + stop hooks + append file
9541d60 fix(t03): quote-aware git command parsing and rename directory helper
83c15e1 test(t03): git HTTPS shell transport tests
cdb44fb refactor(t03): git HTTPS shell transport
0a69d79 test(t02): file system unification tests
1f08671 fix(t02): replace remaining ensureDirectoryExists with createDirectory
7d1eef4 refactor(t02): unify file system access
324a5e9 fix(t04): acceptEdits mode bypasses needsPermission for file edits
55aa2d2 fix(t04): session approval and acceptEdits logic
ff60f72 refactor(phase1): unify permission engine
37e51ad refactor(t01): platform infrastructure and file system interfaces
d00e029 docs: v15 architecture design               ← 架构设计文档
```

---

## 3. 已完成架构决策（不要再改方向）

### Q1 Git HTTPS
- 最终方案：打包静态编译的 `git` 二进制 + `Swift Process`/`posix_spawn` shell out；本地操作保留 libgit2；bundled `cacert.pem` 做 TLS 验证。
- 关键文件：`Services/GitShellService.swift`、`Services/GitService.swift`、`Tools/ExecuteCommandTool.swift`

### Q2 子 Agent 隔离
- 每个子 Agent 独立 `FileSystemService`（基于独立 `PlatformFileSystem`）+ 独立 `PermissionEngine` + 独立 `ConversationSession`。
- `RuntimeExecutor` 作为全局 actor 串行共享，避免 ios_system 进程级状态污染。
- 关键文件：`Agent/SubAgent/SubAgentContext.swift`、`Agent/SubAgent/AgentTool.swift`

### Q3 Skills
- 全部 fork 模式执行，砍 inline。
- `SkillExecutor` 在子 Agent 中真正执行 skill workflow。
- 关键文件：`Agent/Skills/SkillExecutor.swift`、`Tools/SkillTool.swift`

### Q4 Memory
- 保留 JSONL，但改用 `PlatformFileSystem` 创建目录、失败抛错。
- 接 `stopHooks` 在每次 query loop 结束时触发；forked subagent 非阻塞提取。
- 关键文件：`Agent/Memory/MemoryStore.swift`、`Agent/Memory/MemoryExtractor.swift`、`Agent/AgentLoop.swift`

### Q5 文件系统
- `PlatformFileSystem` 统一入口；App 启动时探测 FileManager/posix_spawn/ios_system 三种策略，选定后全量使用；AI 和 UI 共用同一入口。
- 关键文件：`Infrastructure/PlatformFileSystem.swift`、`Infrastructure/PlatformFileSystemStrategy.swift`、`Infrastructure/FileSystemService.swift`

### Q6 权限引擎
- 统一为单一决策点；5 模式（default/acceptEdits/plan/bypassPermissions/dontAsk）+ 三层规则 + safetyCheck bypass 免疫。
- `ToolRegistry.isEnabled(mode)` 在 LLM 侧硬拦截 PlanMode 写工具；`AgentLoop` 不再独立做 PlanMode 拦截。
- 关键文件：`Agent/PermissionEngine.swift`、`Agent/ToolRegistry.swift`、`Agent/AgentLoop.swift`

---

## 4. 你的优先任务清单（按顺序）

### P0：编译与修复编译错误
1. 在 macOS 环境运行：
   ```bash
   cd D:/2/WorkBuddy/2026-06-21-18-14-27/baize
   xcodegen generate
   xcodebuild -project Baize.xcodeproj -scheme Baize -destination 'generic/platform=iOS' build
   ```
2. 修复所有编译错误。常见风险点：
   - `PlatformFileSystem` actor 隔离与 `FileSystemService` 同步调用之间的 Sendable 问题
   - `GitShellService` 中 `posix_spawn` 的 import Darwin
   - `SubAgentContext` 的 Sendable 属性
   - 测试 target 的 bundle 引用
3. 每修一次就 `git add -A && git commit -m "fix(build): ..." && git push origin main`

### P0：替换二进制占位文件
`Baize/Baize/Resources/binaries/` 下目前有三个占位文件：
- `git`
- `mkdir`
- `cacert.pem`

必须替换为真实文件后才能实际运行 Git HTTPS 远程操作：
- `git`：静态编译的 iOS arm64 git 二进制（例如 https://github.com/git-for-windows/git 的 iOS 移植或自己用 Xcode 交叉编译）
- `mkdir`：静态编译的 iOS arm64 mkdir 二进制，或 iOS 系统内可执行路径
- `cacert.pem`：Mozilla CA 证书（curl 官方提供）

推荐资源：
- `https://curl.se/ca/cacert.pem`
- 交叉编译脚本：使用 Xcode toolchain + `iphoneos` SDK 编译 git（复杂，建议先编译一个简单静态 `git`）

### P1：真机运行单元测试
```bash
xcodebuild test -project Baize.xcodeproj -scheme Baize -destination 'id=<你的真机-id>'
```
- 测试文件：`BaizeTests/PermissionEngineTests.swift`、`PlatformFileSystemTests.swift`、`GitShellServiceTests.swift`、`SubAgentSkillMemoryTests.swift`
- 如果测试失败，先判断是源码 Bug 还是测试 Bug，再修复对应一方

### P1：真机验证 5 种权限模式
- default：读工具自动 allow，写工具 ask
- acceptEdits：write_file/edit_file 自动 allow，execute_command 仍 ask
- plan：写工具不出现在 LLM 工具列表，尝试调用直接 deny
- bypassPermissions：写工具自动 allow
- dontAsk：写工具 ask 转 deny
- **重点验证组合**：`bypass + plan` 时写工具仍被拦截（PlanMode 免疫 bypass）

### P1：真机验证文件系统
- 用户手动创建项目 100% 成功
- AI 通过 `execute_command mkdir` 创建目录 100% 成功
- 切换 `PlatformFileSystem` 策略（FileManager/PosixSpawn/IOSSystem）后写文件仍成功

### P2：真机验证 Git HTTPS
- `git clone` 公开仓库成功
- `git fetch` 接收远程对象
- `git push` 成功推送（需要有效 token 和真实 git 二进制）
- 抓包确认没有证书绕过（应使用 TLS 1.2/1.3，证书链完整）

### P2：真机验证 Subagent / Skills / Memory
- 同时启动 3 个子 agent 不串扰（不写入主对话、权限独立）
- 调用 skill 时实际执行 workflow（不是只返回文本）
- 对话结束后 `memory/user/memories.jsonl` 有内容

---

## 5. 已知限制与风险

1. **占位二进制**：git/mkdir/cacert.pem 是空的。Git 远程操作会返回“git 二进制不存在”的明确错误，直到替换真实文件。
2. **混合 commit**：`9541d60` 包含 T03 修复和 T05 部分文件（SubAgentContext/SkillExecutor）。这是已推送的 main 历史，不要 revert/重写，后续保持干净提交即可。
3. **测试未实际运行**：所有测试都是静态逻辑走查，未经过 `xcodebuild test` 真实执行。编译和运行阶段很可能发现 Swift actor/Sendable 问题。
4. **Windows 环境**：当前开发环境没有 Swift/Xcode，无法本地编译。后续必须在 macOS 环境继续。
5. **Skills 旧路径**：`SkillRegistry.executeSkill(name:context:)` 旧 prompt 注入实现可能仍然存在但已不被 `SkillTool` 调用。建议确认后删除 dead code。

---

## 6. 关键文件速查表

| 模块 | 必读文件 |
|------|----------|
| 架构 | `baize/docs/architecture-v15.md` |
| 权限 | `Baize/Baize/Agent/PermissionEngine.swift` |
| 文件系统 | `Baize/Baize/Infrastructure/PlatformFileSystem.swift` |
| Git | `Baize/Baize/Services/GitShellService.swift` |
| 子 Agent | `Baize/Baize/Agent/SubAgent/SubAgentContext.swift` |
| Skills | `Baize/Baize/Agent/Skills/SkillExecutor.swift` |
| Memory | `Baize/Baize/Agent/Memory/MemoryStore.swift` |
| 启动入口 | `Baize/Baize/App/BaizeApp.swift` |
| 项目配置 | `project.yml` |

---

## 7. 如果你只剩很少积分

只做以下三件事，其他留给用户：
1. 跑一次 `xcodegen generate && xcodebuild build` 并修复编译错误。
2. 确认 `Resources/binaries/` 占位文件状态，给用户一个替换清单。
3. commit+push 后结束。

不要开始任何新的架构讨论或大型重构。
