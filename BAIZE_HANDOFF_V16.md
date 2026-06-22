# 白泽 (Baize) — AI 继承者交接文档 v16

> **给下一位 AI 的话**：v15 架构重构已完成。不要再 patch 旧 Bug，直接进入验证、补全、编译/真机阶段。
> **严格按文档指示操作，不要自己瞎猜；不确定的就去核验、查清。**
>
> **生成时间**: 2026-06-23 04:13 | **版本**: v16（替代 v15，因 v15 重构已落地并验证）
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 接手 v15 → 完成 T00–T05 架构重构 → 全量 QA 逻辑走查 → 写 v16 交接文档

---

## 0. TL;DR — 最重要的事先说

1. **项目位置**: `D:\2\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe（分支 `main`）
3. **最新 commit**: `9055111 docs: v16 handoff after v15 refactor completion`
4. **最新 CI**: 未触发（本次只改 .md 文档，CI 忽略 *.md 路径）。**上一条跑过 CI 的 commit 是 `c2697d8`**，但当前 main 已超过该 commit，**下一次非 docs 提交会触发新的 CI**。你需要立刻做一次真机验证或编译修复，触发 CI 并确认通过。
5. **Token**: 已嵌入 git remote URL，不要写明文，GitHub secret scanning 会拒绝 push。
6. **当前状态**: ✅ v15 架构重构完成；⚠️ 未实际编译/真机验证；⚠️ 二进制占位文件需替换。
7. **积分警告**: 用户积分已耗尽。每做一步就 commit+push，随时可能被中断。
8. **下一步首要任务**: 在 macOS 上 `xcodegen generate && xcodebuild build` → 修编译错误 → 替换二进制占位文件 → 真机测试。

---

## 1. 项目身份与运行环境

| 字段 | 值 |
|------|------|
| **名称** | 白泽 (Baize) — iOS 本地编程智能体 |
| **类比** | 像 Claude Code / Codex，但跑在 iPad Pro M1 本地 |
| **运行环境** | iPad Pro 2021 M1, iOS 16.6.1, 通过 TrollStore 免签安装 |
| **构建方式** | GitHub Actions CI (macos-14 runner, Xcode 15.4) → 编译 IPA → ldid fakesign → 下载安装 |
| **技术栈** | Swift 6 + SwiftUI \| libgit2 C API \| nodejs-mobile (--jitless) \| CPython 3.13 \| ios_system \| Monaco Editor (WKWebView) |
| **GitHub 仓库** | https://github.com/Da-AiXZ/BaiZe |
| **分支** | main |
| **本地路径** | `D:\2\WorkBuddy\2026-06-21-18-14-27\baize` |
| **GitHub Token** | `<见 git remote URL，不要写明文>` |
| **最新 commit** | `9055111` |
| **上一条触发 CI 的 commit** | `c2697d8` |
| **IPA 目标** | iOS 16.0+, arm64, ldid fakesign, TrollStore 安装 |

### Token 获取方式（严禁写明文）

- **方式 1**: `git -C "D:\2\WorkBuddy\2026-06-21-18-14-27\baize" remote -v` 输出里包含 token
- **方式 2**: 问用户要
- **方式 3**: 检查 `D:\2\WorkBuddy\2026-06-21-18-14-27\baize\.workbuddy\memory\MEMORY.md`（但项目 memory 中可能不存 token）

⚠️ **历史教训**: 交接文档里曾写明文 token，结果 GitHub secret scanning 拒绝 push，直接堵死后续提交。必须只写 `<见 git remote>` 或 `<问用户>`。

---

## 2. 本次会话发生了什么（时间线）

### 阶段一：读资料 + 建立团队（02:00–02:36）

- 读取 v15 交接文档、PRD v15、架构师输入包、Claude Code 源码（已解压到 `D:/111/2026-06-23-02-36-07/.tmp/claude/claude-code/`）。
- 创建团队 `software-baize-refactor`（主理人齐活林 + 架构师高见远 + 工程师寇豆码 + QA 严过关）。
- 团队任务是完成 v15 架构重构（文件系统/Git HTTPS/SubAgent/Skills/Memory/权限引擎）。

### 阶段二：T00 架构设计（02:36–02:50）

- 架构师高见远输出 `baize/docs/architecture-v15.md` + `class-diagram.mermaid` + `sequence-diagram.mermaid`。
- 回答了 6 个技术选型问题（Q1 Git HTTPS / Q2 SubAgent 隔离 / Q3 Skills / Q4 Memory / Q5 文件系统 / Q6 权限引擎）。
- 提交 `d00e029`。

### 阶段三：T01–T05 实现（02:50–04:00）

| Phase | 主题 | 关键提交 | 状态 |
|-------|------|----------|------|
| T01 | 基础设施 + 平台接口 | `37e51ad` | ✅ 完成 |
| T02 | 文件系统统一 | `7d1eef4` + `1f08671` | ✅ 完成 |
| T03 | Git HTTPS 传输层 | `cdb44fb` + `83c15e1` + `9541d60` | ✅ 完成 |
| T04 | 权限引擎统一 | `ff60f72` + `55aa2d2` + `324a5e9` | ✅ 完成 |
| T05 | 子 Agent + Skills + Memory | `9541d60` + `2a7e4b3` + `c2697d8` | ✅ 完成 |

- 工程师寇豆码负责 T01/T03/T04 初步实现；T02 由主理人直接补齐；T05 由工程师 + 主理人共同完成。
- QA 严过关对每个 Phase 做静态逻辑走查 + 新增测试文件（4 个测试文件）。
- 过程中修复了 T04 的 Session Approval 失效、acceptEdits 未自动允许、T05 的 MemoryStore baseDir 未生效等源码 Bug。

### 阶段四：写 v16 交接文档（04:00–04:13）

- 用户积分耗尽，要求写交接文档。
- 主理人对比 V12–V15 交接文档结构，补全 V16 缺失的 Token、项目身份、CI/CD、踩坑记录、文件结构、测试分层等部分。
- 提交 `9055111`。

---

## 3. v15 重构后的文件结构

```
baize/
├── BAIZE_HANDOFF_V16.md          ← 本文档
├── project.yml                   ← XcodeGen 项目配置（新增 Resources/binaries 资源引用）
├── .github/workflows/build.yml   ← CI/CD 配置
├── docs/
│   ├── architecture-v15.md        ← 架构设计文档（必读）
│   ├── class-diagram.mermaid
│   └── sequence-diagram.mermaid
└── Baize/Baize/
    ├── App/
    │   ├── BaizeApp.swift         ← 启动入口：创建 PlatformFileSystem、注入所有服务
    │   └── AppState.swift         ← 全局状态：project 切换时重建 GitShellService/GitService
    ├── Agent/
    │   ├── AgentLoop.swift        ← 支持 stopHooks、effectiveMode 工具过滤
    │   ├── PermissionEngine.swift ← 5 模式统一决策点（唯一权限门）
    │   ├── ToolRegistry.swift     ← isEnabled(mode:) 硬拦截层
    │   ├── Tool.swift
    │   ├── PlanMode/
    │   │   └── PlanModeState.swift ← 只保留状态机，权限判断交给 PermissionEngine
    │   ├── SubAgent/
    │   │   ├── AgentTool.swift    ← 使用 SubAgentContext 创建子 AgentLoop
    │   │   └── SubAgentContext.swift ← 新增：隔离上下文（独立 FS/权限/会话）
    │   ├── Skills/
    │   │   ├── Skill.swift
    │   │   ├── SkillParser.swift
    │   │   ├── SkillRegistry.swift
    │   │   └── SkillExecutor.swift ← 新增：fork 子 Agent 真正执行 skill
    │   ├── Memory/
    │   │   ├── Memory.swift
    │   │   ├── MemoryStore.swift   ← 改为 PlatformFileSystem 写入，baseDir 生效
    │   │   └── MemoryExtractor.swift ← 接 stopHooks + 错误捕获
    │   └── ConversationStore.swift
    ├── Services/
    │   ├── GitService.swift        ← 本地操作仍走 libgit2，远程操作路由到 GitShellService
    │   └── GitShellService.swift   ← 新增：posix_spawn 调用 bundle 内 git 二进制 + CA 证书
    ├── Infrastructure/
    │   ├── PlatformFileSystem.swift        ← 新增：文件系统统一入口（actor）
    │   ├── PlatformFileSystemStrategy.swift ← 新增：FileSystemStrategy 协议 + 3 种实现
    │   ├── FileSystemService.swift         ← 改为 PlatformFileSystem 的同步包装
    │   └── RuntimeExecutor.swift           ← 共享使用，子 Agent 不独立创建
    ├── Tools/
    │   ├── ExecuteCommandTool.swift  ← 拦截 git 命令转 GitShellService
    │   ├── SkillTool.swift           ← 调用 SkillExecutor 真正执行
    │   ├── WriteFileTool.swift
    │   ├── EditFileTool.swift
    │   └── ...（其他工具）
    ├── Views/
    │   ├── Chat/ChatView.swift       ← 注册 AgentLoop stopHook 触发 Memory 提取
    │   ├── Dashboard/NewProjectWizard.swift
    │   └── ...
    ├── Utils/
    │   ├── Constants.swift           ← 新增 BaizeBinary 路径常量
    │   └── Extensions.swift          ← 删除 4 级回退 ensureDirectoryExists
    ├── Resources/
    │   └── binaries/                ← 新增：git、mkdir、cacert.pem（占位文件，需替换）
    └── BaizeTests/
        ├── PermissionEngineTests.swift
        ├── PlatformFileSystemTests.swift
        ├── GitShellServiceTests.swift
        └── SubAgentSkillMemoryTests.swift
```

---

## 4. 架构决策速查（不要再改方向）

### Q1 Git HTTPS
- **选择**: 打包静态编译的 `git` 二进制 + `posix_spawn` shell out；本地操作保留 libgit2；bundled `cacert.pem` 做 TLS 验证。
- **原因**: libgit2+OpenSSL 在 iOS TrollStore 下访问不了系统 Keychain CA 证书，且“接受任何证书”是 MITM 漏洞。
- **关键文件**: `Services/GitShellService.swift`、`Services/GitService.swift`、`Tools/ExecuteCommandTool.swift`

### Q2 子 Agent 隔离
- **选择**: 每个子 Agent 独立 `PlatformFileSystem` + 独立 `PermissionEngine` + 独立 `ConversationSession`；`RuntimeExecutor` 作为全局 actor 串行共享。
- **原因**: 共享 `RuntimeExecutor` 的 posix_spawn pipe 不线程安全；共享 `PermissionEngine` 会导致权限污染。
- **关键文件**: `Agent/SubAgent/SubAgentContext.swift`、`Agent/SubAgent/AgentTool.swift`

### Q3 Skills
- **选择**: 全部 fork 模式执行，砍 inline；`SkillExecutor` 在子 Agent 中真正执行 skill workflow。
- **原因**: iOS 不能 spawn shell，但可以在同进程内创建独立 AgentLoop actor 实例并发运行。
- **关键文件**: `Agent/Skills/SkillExecutor.swift`、`Tools/SkillTool.swift`

### Q4 Memory
- **选择**: 保留 JSONL，但改用 `PlatformFileSystem` 创建目录、失败抛错；接 `stopHooks` 在每次 query loop 结束时触发；forked subagent 非阻塞提取。
- **原因**: 原实现目录创建静默失败（`try? fm.ensureDirectoryExists` 吃掉了错误），且从未接触发点。
- **关键文件**: `Agent/Memory/MemoryStore.swift`、`Agent/Memory/MemoryExtractor.swift`、`Agent/AgentLoop.swift`

### Q5 文件系统
- **选择**: `PlatformFileSystem` 统一入口；App 启动时探测 FileManager / posix_spawn / ios_system 三种策略，选定单一可靠机制后全量使用；AI 和 UI 共用同一入口。
- **原因**: 4 级回退不可维护，必须统一为 1 套可用方案。
- **关键文件**: `Infrastructure/PlatformFileSystem.swift`、`Infrastructure/PlatformFileSystemStrategy.swift`、`Infrastructure/FileSystemService.swift`

### Q6 权限引擎
- **选择**: 统一为单一决策点；5 模式（default/acceptEdits/plan/bypassPermissions/dontAsk）+ 三层规则 + safetyCheck bypass 免疫；`ToolRegistry.isEnabled(mode)` 在 LLM 侧硬拦截 PlanMode 写工具；`AgentLoop` 不再独立做 PlanMode 拦截。
- **原因**: PermissionEngine + PlanModeState + AgentLoop 三层各自判断导致 bypass/PlanMode 不同步。
- **关键文件**: `Agent/PermissionEngine.swift`、`Agent/ToolRegistry.swift`、`Agent/AgentLoop.swift`

---

## 5. 最新 Commit 历史（必读）

```
9055111 docs: v16 handoff after v15 refactor completion  ← 最新（本文档）
c2697d8 fix(t05): MemoryStore baseDir path                ← 上一条功能 commit
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
d00e029 docs: v15 architecture design
```

---

## 6. 你的优先任务清单（按顺序）

### P0：编译并修复编译错误
1. 在 macOS 环境运行：
   ```bash
   cd D:/2/WorkBuddy/2026-06-21-18-14-27/baize
   xcodegen generate
   xcodebuild -project Baize.xcodeproj -scheme Baize -destination 'generic/platform=iOS' build
   ```
2. 修复所有编译错误。常见风险点：
   - `PlatformFileSystem` actor 隔离与 `FileSystemService` 同步调用之间的 Sendable 问题
   - `GitShellService` 中 `posix_spawn` 的 `import Darwin`
   - `SubAgentContext` 的 Sendable 属性
   - 测试 target 的 bundle 引用
3. 每修一次就 `git add -A && git commit -m "fix(build): ..." && git push origin main`
4. 确认 CI 通过后再继续下一步。

### P0：替换二进制占位文件
`Baize/Baize/Resources/binaries/` 下目前有三个占位文件：
- `git`（空）
- `mkdir`（空）
- `cacert.pem`（空）

必须替换为真实文件后才能实际运行 Git HTTPS 远程操作：
- `git`：静态编译的 iOS arm64 git 二进制（例如自行用 Xcode toolchain 交叉编译）
- `mkdir`：静态编译的 iOS arm64 mkdir 二进制，或 iOS 系统内可执行路径
- `cacert.pem`：Mozilla CA 证书（`https://curl.se/ca/cacert.pem`）

### P1：真机运行单元测试
```bash
xcodebuild test -project Baize.xcodeproj -scheme Baize -destination 'id=<你的真机-id>'
```
- 测试文件：`BaizeTests/PermissionEngineTests.swift`、`PlatformFileSystemTests.swift`、`GitShellServiceTests.swift`、`SubAgentSkillMemoryTests.swift`
- 如果测试失败，先判断是源码 Bug 还是测试 Bug，再修复对应一方。

### P1：真机验证 5 种权限模式
- **default**：读工具自动 allow，写工具 ask
- **acceptEdits**：write_file/edit_file 自动 allow，execute_command 仍 ask
- **plan**：写工具不出现在 LLM 工具列表，尝试调用直接 deny
- **bypassPermissions**：写工具自动 allow
- **dontAsk**：写工具 ask 转 deny
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

## 7. CI/CD 管道速查

### 工作流文件
`.github/workflows/build.yml`

### CI 步骤顺序
```
Checkout → Select Xcode 15.4 → Install tools (brew ldid xcodegen + gem xcpretty)
→ Cache SPM → Configure git HTTPS → xcodegen generate
→ Resolve SPM → Patch ios_system xcframeworks → Download Runtime binaries
→ Build libgit2 xcframework → Patch repo-local xcframeworks
→ Download Monaco Editor → xcodebuild archive
→ build-ipa.sh → verify-ipa.sh → Upload IPA artifact
```

### 构建关键参数
- **Runner**: `macos-14` + Xcode 15.4
- **SDK**: `iphoneos`, arch `arm64`
- **签名**: ldid fakesign（适合 TrollStore，非 Apple 证书）
- **部署目标**: iOS 16.0（CI 实际用 17.5 SDK，但 patch 到 16.0）
- **IPA 输出**: `output/Baize.ipa`
- **注意**: XcodeGen 2.45 生成 objectVersion 77，CI 用 sed 改为 60 以兼容 Xcode 15.4

### 如何查看 CI 状态（Windows Git Bash）

```bash
export GH_TOKEN="<见 git remote URL 或问用户>"

# 最近 5 次 CI 运行
curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs?per_page=5" \
  | python -c "import json,sys; [print(f\"#{r['run_number']} | {r['status']}/{r['conclusion']} | {r['head_sha'][:7]}\") for r in json.load(sys.stdin)['workflow_runs']]"

# 查看特定 Run 的失败步骤
curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/<RUN_ID>/jobs" \
  | python -c "import json,sys; [print(f\"{j['name']}: {j['conclusion']}\") for j in json.load(sys.stdin)['jobs']]"

# 下载失败日志
JOB_ID=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/<RUN_ID>/jobs" \
  | python -c "import json,sys; print(json.load(sys.stdin)['jobs'][0]['id'])")
curl -sL -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/jobs/${JOB_ID}/logs" \
  -o /tmp/ci-logs.txt
```

---

## 8. 已知限制与风险

1. **占位二进制**：git/mkdir/cacert.pem 是空的。Git 远程操作会报“git 二进制不存在”，直到替换真实文件。
2. **混合 commit**：`9541d60` 同时包含 T03 修复和 T05 部分新增文件（SubAgentContext/SkillExecutor）。这是已推送的 main 历史，**不要 revert/重写**，后续保持干净提交即可。
3. **测试未实际运行**：所有测试都是静态逻辑走查，未经过 `xcodebuild test` 真实执行。编译阶段很可能发现 Swift actor/Sendable 问题。
4. **Windows 环境限制**：当前开发环境无 Swift/Xcode，无法本地编译。后续必须在 macOS 环境继续。
5. **Skills 旧路径**：`SkillRegistry.executeSkill(name:context:)` 旧 prompt 注入实现可能仍然存在但已不被 `SkillTool` 调用。建议确认后删除 dead code。
6. **CI 未验证最新 main**：`9055111` 是 docs commit，不触发 CI。`c2697d8` 是最后触发 CI 的功能 commit，但 main 上已有更多改动。需要一次新提交来触发 CI 并确认通过。

---

## 9. 踩坑记录（本次会话新增）

1. **GitHub secret scanning 拒绝 push**：交接文档里写明文 token 会导致 push 被拒。V16 已改为只写 `<见 git remote>`，不要重蹈覆辙。
2. **V15 与 V16 的过渡文件路径**：用户已将项目从 `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize` 迁移到 `D:\2\WorkBuddy\2026-06-21-18-14-27\baize`。当前使用 D 盘路径，但 CI 只认 GitHub 仓库内容，不受本地路径影响。
3. **T04 权限引擎修复经过 3 轮**：Session Approval 失效 → acceptEdits 未自动允许 → acceptEdits 仍被 needsPermission 降级。最终方案是在 PermissionEngine Step 5 跳过 acceptEdits 的文件编辑工具，Session Approval 放到 Step 6 最终覆盖。
4. **T05 MemoryStore baseDir 未生效**：第一次实现只改了 init 但路径仍硬编码。QA 发现后要求 memoryFilePath 基于 baseDir 构造，已修复。
5. **commit 历史不要重写**：`9541d60` 是已推送的混合提交，revert 会导致 T05 新文件从 main 删除。保持现状、后续干净提交是正确做法。

---

## 10. 关键文件速查表

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
| CI | `.github/workflows/build.yml` |

---

## 11. 如果你只剩很少积分

只做以下三件事，其他留给用户：
1. 跑一次 `xcodegen generate && xcodebuild build` 并修复编译错误。
2. 确认 `Resources/binaries/` 占位文件状态，给用户一个替换清单。
3. commit+push 后结束。

不要开始任何新的架构讨论或大型重构。
