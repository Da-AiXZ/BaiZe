# 白泽 (Baize) — AI 继承者交接文档 v13

> **给下一位 AI 的话**：这份文档就是你的"记忆"。读完 ≈ 你跟着我从头干到了这里。
> 严格按文档指示操作，不要自己瞎猜。
>
> **生成时间**: 2026-06-22 01:15 | **版本**: v13（替代 v12，因重构方案已落地代码）
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 从"iOS 编程工具"重构为"对标 Claude Code/Codex 的 iOS 端全能 Agent"

---

## 0. TL;DR — 最重要的事先说

1. **项目位置**: `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe (分支 `main`)
3. **GitHub Token**: 见下方"Token 获取方式"（不能写明文，GitHub secret scanning 会拒绝 push）
4. **最新已提交 commit**: `72376b6` (2026-06-21，交接文档 v12)
5. **当前工作区状态**: **大量未提交改动**（T01-T04 重构代码，47 个文件改动，未 commit 未 push）
6. **重构进度**: T01-T04 代码已写完，工程师报告 IS_PASS: YES，但 **QA 测试未完成**（用户积分用尽叫停）
7. **下一步首要任务**: QA 验证 → 修 Bug → commit → push → CI 构建 → 真机测试

---

## 1. 本次会话发生了什么（时间线）

### 阶段一：接手 + 真机测试第 3-4 层（22:21 - 23:02）

- 接手 v12 交接文档，确认项目状态
- 引导用户做第 3 层真机测试（代码执行）：
  - RunPython/RunNode 工具成功 ✅（posix_spawn + nodejs-mobile --jitless 真机跑通）
  - 发现 2 个新 Bug（工具执行参数显示"无"/终端历史重启清空）
- 第 4 层 Git 测试：用户反馈"项目走歪了，和 Claude Code 差好多"，叫停测试

### 阶段二：用户给材料，重新设计方案（23:02 - 23:48）

用户提供了 3 份材料让我研究后重新设计：
- `cc-haha-main.zip` — 桌面端 Claude Code 工作台（Electron+React+Bun）
- `白泽.zip` — 26 个 Agent 框架源码 + 研究文献（harness/scaffolding/prompt/context engineering）
- `Operit-main.zip` — Android 端全能 Agent（1046 个 Kotlin 文件）

用户的核心诉求：
> "整个项目走歪了，和 Claude Code/Codex 差好多，核心没搞完光堆不必要的功能，就像晚期苏联，重工业发达轻工业薄弱。我要 iOS 端对标 Codex/Claude Code 一样强的全能 Agent。以白泽为基底，不推倒重来。"

我输出了两份方案文档：
- `白泽重构方案_v1.md` — 走歪诊断 + 重构方向
- `白泽重构方案_v2_6决策.md` — 基于 Operit 研究的 6 个决策

### 阶段三：拉团队执行 SOP（23:48 - 01:09）

创建团队 `software-baize-refactor`，走标准 SOP：

1. ✅ **产品经理许清楚** → PRD（`PRD_白泽重构_v1.md`）
2. ✅ **架构师高见远** → 架构设计 + iOS 可行性逐项验证（`ARCH_白泽重构_v1.md`）
   - 30 个设计点验证：28 ✅完全可行 / 2 ⚠️需关注 / 0 ❌不可行
   - 关键验证：MCP 本地 posix_spawn+pipe **已验证可行**（白泽 PythonSpawnStrategy 已有先例）
3. ✅ **工程师寇豆码** → T01-T04 四个任务全部 IS_PASS: YES
4. ⏸️ **QA 严过关** → 测试未完成（用户积分用尽叫停）

---

## 2. 重构方案核心（必读）

### 走歪诊断

| 维度 | 白泽重构前 | Claude Code 参考 | 差距 |
|------|----------|----------------|------|
| 工具数量 | 10 个 | 40+ | 4 倍 |
| Skills 系统 | ❌ 无 | ✅ 有 | 完全缺失 |
| Memory 系统 | ❌ 只有对话历史 | ✅ memdir | 完全缺失 |
| Sub-agent | ❌ 无 | ✅ AgentTool | 完全缺失 |
| MCP 集成 | ❌ 无 | ✅ 有 | 完全缺失 |
| PlanMode | ❌ 无 | ✅ 有 | 完全缺失 |
| Slash Commands | ❌ 无 | ✅ 50+ | 完全缺失 |
| Git Tab | 7 子视图手动操作 | AI 自主 | 重工业过剩 |
| 主界面 | 5 Tab 平级 | 聊天为主 | 交互走歪 |

### 重构三件事

1. **补轻工业**：Tool 接口扩展 + 15+ 新工具 + Skills + Memory + Slash + Sub-agent + PlanMode + MCP
2. **砍重工业**：Git Tab 7 子视图砍手动操作 / Editor 砍手编 / Terminal 砍手输 / Dashboard 简化
3. **改交互**：5 Tab 平级 → 聊天为主 + 工作台侧栏（参考 cc-haha）

### 6 个已定决策（不可更改）

| # | 决策 | 选择 |
|---|------|------|
| 1 | WebSearch | 多搜索引擎架构，默认 Tavily，可选 Bing/Google/DuckDuckGo |
| 2 | MCP 优先级 | 从 R4 提前到 R2 |
| 3 | 交互重构时机 | R1 与 R3 并行（独立分支） |
| 4 | Skills 内置清单 | P0 内置 8 个（commit-push/review/debug-error/fix-bug/refactor/test-gen/explain-code/new-feature） |
| 5 | Memory 自动提取 | 开启，三阶段递进（R1 文件+关键词 → R4 打分+SQLite → R5 向量） |
| 6 | Git Tab 处置 | 砍手动操作，保留只读查看（status/log/diff）+ 工作台侧栏 |

---

## 3. 架构设计要点（架构师高见远产出）

### iOS 可行性验证结论

- **✅ 完全可行**：28 项（93%）
- **⚠️ 需关注**：2 项
  - Q7 MCP 本地 posix_spawn+pipe → **已验证可行**（白泽 PythonSpawnStrategy 已有先例，只需扩展为双向 pipe）
  - Q8 向量记忆 → 技术可行但**推荐远程嵌入 API**（onnxruntime-ios 增 50-80MB 体积不可接受）
- **❌ 不可行**：0 项

### 零新增第三方依赖

R1/R2/R3 不引入任何新 SPM 包。R4 链接系统自带 libsqlite3.tbd。R5 用远程嵌入 API（不引入 onnxruntime-ios）。

### 关键架构决策

1. Tool 协议扩展用 **protocol extension 默认值**：现有 10 个工具零改动编译通过
2. ToolExecutionContext 新增属性**全部可选（?）**：现有工具 execute 方法不受影响
3. AgentEvent 新增 14 个 case，全部保持 `@unchecked Sendable`
4. Skills 复用 ProjectContext.parseBaizeMD() 的 YAML frontmatter 解析模式
5. Memory 自动提取复用 ContextManager.generateSummary() 的 LLM 调用 + 超时降级模式
6. PlanMode 与现有 PermissionMode.plan 协同
7. Sub-agent **不需 fork**：创建新 AgentLoop actor 实例，同进程内并发运行

---

## 4. T01-T04 已完成代码（⚠️ 未提交）

### 工作区状态

```
47 个文件改动（未 commit 未 push）：
- 18 个新增 Swift 文件
- 15 个修改 Swift 文件
- 5 个删除文件（4 个 Git 视图 + 旧交接文档）
- 8 个新增 SKILL.md
- 1 个新增 Workbench 目录（5 文件）
- 1 个新增 Dialogs 目录（2 文件）
- 1 个新增 Settings 目录（3 文件）
```

### T01 项目基础设施（7 文件修改）

| 文件 | 改动 |
|------|------|
| `Agent/Tool.swift` | Tool 协议扩展（permissionLevel/category/needsPermission/isAvailable）+ 3 枚举 + ToolExecutionContext 新增 8 可选属性 |
| `Agent/AgentEvent.swift` | 新增 14 case（8 R1 + 6 R2）+ 3 占位类型（TodoItem/UserQuestion/TaskItem） |
| `Agent/PermissionEngine.swift` | findTool 改 async + needsPermission 检查 |
| `Agent/ToolRegistry.swift` | 新增 getTool/getToolsByCategory/getAvailableTools |
| `Utils/Constants.swift` | BaizePath 新增 8 路径 + BaizeToken 新增 2 常量 + BaizeAPI 新增 4 端点 |
| `Models/AppState.swift` | 新增占位空 actor + WebSearchProvider 协议 + 8 可选服务属性 |
| `App/BaizeApp.swift` | 占位 actor 实例化 + 注入 |

**⚠️ 命名偏差**：架构文档写 `PermissionDecision`，但 PermissionEngine.swift 已存在同名 struct。工程师改为 `ToolPermissionDecision` 避免冲突。PermissionEngine 的 `PermissionDecision` 是最终权威决策，`ToolPermissionDecision` 是工具自评估。

### T02 R1 核心系统层（14 Swift + 8 SKILL.md）

**Skills 系统**（3 文件）：
- `Agent/Skills/Skill.swift` — Skill 数据模型
- `Agent/Skills/SkillParser.swift` — SKILL.md 解析（YAML frontmatter + Markdown）
- `Agent/Skills/SkillRegistry.swift` — actor，三级目录扫描 + matchSkill + executeSkill

**Memory 系统**（3 文件）：
- `Agent/Memory/Memory.swift` — Memory 数据模型 + MemoryScope + MemoryType
- `Agent/Memory/MemoryStore.swift` — actor，JSONL 存储 + findRelevantMemories（关键词匹配 + 时间衰减）
- `Agent/Memory/MemoryExtractor.swift` — 会话结束自动提取（复用 generateSummary 超时降级模式）

**Slash Commands**（2 文件）：
- `Agent/Commands/SlashCommand.swift` — 协议 + 10 个内置命令
- `Agent/Commands/CommandRegistry.swift` — actor，注册/解析/执行

**PlanMode**（1 文件）：
- `Agent/PlanMode/PlanModeState.swift` — actor，enter/exit/approve/reject

**WebSearch**（5 文件）：
- `Agent/WebSearch/WebSearchProvider.swift` — 协议 + WebSearchResult + WebSearchFactory（降级策略）
- `Agent/WebSearch/TavilySearchProvider.swift` — 默认
- `Agent/WebSearch/BingSearchProvider.swift`
- `Agent/WebSearch/GoogleSearchProvider.swift`
- `Agent/WebSearch/DuckDuckGoSearchProvider.swift` — 免 API key 兜底

**8 个 SKILL.md**：
- `Resources/skills/{commit-push,review,debug-error,fix-bug,refactor,test-gen,explain-code,new-feature}/SKILL.md`

**修改文件**：
- `Agent/ContextManager.swift` — buildSystemPrompt 改 async + Memory 注入
- `App/BaizeApp.swift` — 实例化新服务并注入
- `Models/AppState.swift` — 删除 5 占位，引用真实实现
- `Utils/Logger.swift` — 新增 5 个 Logger
- `Agent/AgentLoop.swift` — agentLoop 新增 userQuery 参数 + .memoryInjected 事件

**⚠️ 命名偏差**：架构文档写 `SearchResult`，但 FileSystemService 已有同名。工程师改为 `WebSearchResult` 避免冲突。

### T03 R1 工具层 + R3 交互重构

**7 个新工具**（Tools/ 目录）：
- `TodoWriteTool.swift` — AI 维护任务清单（autoAllow/planning）
- `AskUserQuestionTool.swift` — 结构化多问题提问（autoAllow/planning）
- `WebFetchTool.swift` — 抓取 URL + LLM 摘要（autoAllow/web）
- `WebSearchTool.swift` — 网络搜索（autoAllow/web）
- `EnterPlanModeTool.swift` — 进入计划模式（autoAllow/planning）
- `ExitPlanModeTool.swift` — 退出计划模式提交审批（autoAllow/planning）
- `SkillTool.swift` — 调用已安装 Skill（askUser/skill）

**AgentLoop 集成**：
- 新增 5 个存储属性（skillRegistry/memoryStore/commandRegistry/planModeState/webSearchProvider）
- PlanMode 拦截写操作（.allow 路径检查 isInPlanMode + isToolReadOnly）
- emitSpecialToolEvents 发射特殊工具事件
- Memory 提取用 Task.detached 异步不阻塞 .completed

**ContentView 重构**：
- 横屏：NavigationSplitView { FileExplorer } detail: { R3WorkspacePane（聊天 + WorkbenchSidebar 360pt）}
- 竖屏：TabView 4 Tab（工作区/工作台/首页/设置）

**5 个 Workbench 组件**：
- `Views/Workbench/WorkbenchSidebar.swift` — 5 个 DisclosureGroup 可折叠区域
- `Views/Workbench/TaskListView.swift`
- `Views/Workbench/FileChangesPanel.swift`
- `Views/Workbench/CommandOutputView.swift`
- `Views/Workbench/DiffViewer.swift`

**2 个 Dialog**：
- `Views/Dialogs/PlanApprovalView.swift` — @MainActor sheet
- `Views/Dialogs/AskUserQuestionView.swift` — @MainActor sheet

**3 个 Settings**：
- `Views/Settings/SearchEngineSettingsView.swift`
- `Views/Settings/MemorySettingsView.swift`
- `Views/Settings/SkillsManagerView.swift`

**删除 4 个 Git 视图**：
- GitBranchView / GitStashView / GitTagListView / GitSubTabView（已验证零残留引用）

**修改现有视图**：
- GitStatusView → 改只读
- GitDiffView → 增强
- GitLogView → 改只读
- TerminalPane → 移除输入框
- TerminalViewModel → 简化
- EditorContainerView → 简化为只读 + diff
- DashboardView → 简化为侧栏统计
- SettingsView → 新增 3 个入口
- ChatView → 14 个新 AgentEvent case 处理 + 2 个 sheet
- ChatInputView → 命令/技能检测

### T04 R2 Sub-agent + MCP 远程

**Sub-agent 系统**（4 文件）：
- `Agent/SubAgent/TaskItem.swift` — 完整版 TaskItem（替换 T01 占位）
- `Agent/SubAgent/TaskList.swift` — actor，共享任务列表
- `Agent/SubAgent/TeamCoordinator.swift` — actor，agents/inboxes 管理
- `Agent/SubAgent/AgentTool.swift` — spawn 子 agent 工具

**MCP 系统**（3 文件）：
- `Agent/MCP/MCPServerConfig.swift` — 配置模型 + UserDefaults 持久化
- `Agent/MCP/MCPToolExecutor.swift` — JSON-RPC 2.0 over HTTP + MCPServerConnection
- `Agent/MCP/MCPManager.swift` — actor，连接管理

**6 个新工具**：
- `Tools/TaskCreateTool.swift` / `TaskUpdateTool.swift` / `TaskListTool.swift` / `TaskGetTool.swift`
- `Tools/SendMessageTool.swift`
- `Tools/MCPTool.swift`

**工具总数**：10 现有 + 7 R1 + 7 R2 = **24 个工具**

### 全局一致性审查结果

工程师寇豆码 T01-T04 全部报告 **IS_PASS: YES**。但注意：**QA 严过关的独立验证未完成**，不能盲信 IS_PASS。

---

## 5. ⚠️ 下一位 AI 的首要任务

### 任务 1：QA 验证（最高优先）

QA 严过关已被派出但未完成测试就被叫停。下一位 AI 必须：

1. 读架构文档 `D:/111/2026-06-21-22-21-21/ARCH_白泽重构_v1.md` §1 iOS 可行性验证
2. 读 PRD `D:/111/2026-06-21-22-21-21/PRD_白泽重构_v1.md`
3. 对 T01-T04 代码做独立 QA 验证，重点 12 项：
   - 编译通过性（类型引用、actor 隔离、Sendable 合规）
   - Tool 协议一致性（现有 10 工具零改动 + 14 新工具正确实现）
   - AgentEvent 完整性（14 case 处理 + TaskItem 占位替换）
   - 占位替换完整性（T01 的 7 占位是否全部替换）
   - ToolRegistry 24 工具注册
   - AgentLoop 集成（新参数可选 + PlanMode 拦截 + Memory 提取）
   - Skills/Memory/MCP/Sub-agent 系统正确性
   - ContentView 重构 + 删 4 Git 视图无残留
   - Swift 6 严格模式
4. 发现 Bug → 反馈工程师修复 → 回归验证

### 任务 2：Commit + Push + CI

QA 通过后：
```bash
cd "C:/Users/netease/WorkBuddy/2026-06-21-18-14-27/baize"
git add -A
git commit -m "feat: 白泽重构 R1+R2+R3 — 对标 Claude Code/Codex

- T01 项目基础设施：Tool 协议扩展 + 14 AgentEvent case + 占位 actor
- T02 R1 核心系统：Skills(8 内置) + Memory(文件+关键词) + Slash(10 命令) + PlanMode + WebSearch(4 引擎)
- T03 R1 工具层 + R3 交互重构：7 新工具 + ContentView 5Tab→聊天+工作台 + 删 4 Git 视图
- T04 R2 Sub-agent + MCP 远程：AgentTool + Task 系列 + MCPManager + JSON-RPC

工具总数 10→24，新增 39 Swift 文件 + 8 SKILL.md

Refs: PRD_白泽重构_v1.md, ARCH_白泽重构_v1.md"
git push origin main
```

然后前台盯 CI（用户要求不用后台）：
```bash
export GH_TOKEN="<从 memory 或 git remote 读>"
# 轮询 CI 状态，每 45-60 秒检查一次
```

### 任务 3：修 CI 错误（如果有）

CI 大概率会失败（Swift 6 严格模式 + 大量新代码）。预期错误类型：
- actor 隔离错误
- Sendable 合规错误
- 类型引用错误
- 缺少 await

修 CI 错误走 BugFix 快捷路径：
1. 拉团队（TeamCreate → software-bugfix-baize）
2. 工程师寇豆码定位修复
3. QA 严过关回归测试
4. 前台盯 CI 直到通过

### 任务 4：真机测试

CI 通过生成新 IPA 后：
1. 用户安装新 IPA
2. 引导用户逐层测试（第 3-8 层）
3. 收集 Bug → BugFix 快捷路径修复

---

## 6. 后续 Phase 路线（T05 未做）

### T05: R4+R5 高级 + 打磨（P2+P3，未开始）

| 模块 | Phase | 内容 |
|------|-------|------|
| MCP 本地 | R4 | posix_spawn + 双向 pipe（复用 PythonSpawnStrategy 模式扩展 stdin） |
| Memory 阶段2 | R4 | SQLite 存储 + 打分公式 S_kw+S_rev+S_sem+S_graph + LLM 结构化决策 |
| TeamCreate/Delete | R4 | 多 agent 团队创建/删除工具 |
| compact 优化 | R4 | 改进 prompt + 分段压缩 |
| Memory 阶段3 | R5 | 远程嵌入 API（OpenAI text-embedding-3-small）+ 暴力余弦相似度 |
| Skills 市场 | R5 | 从 GitHub 安装技能（参考 OpenSkills） |
| 触屏优化 | R5 | diff 查看 + 权限审批触屏体验 |
| 离线运行 | R5 | 离线场景核心功能 |

**T05 依赖**：T01-T04 完成 + QA 通过 + CI 通过

---

## 7. 项目身份与仓库

| 字段 | 值 |
|------|------|
| 名称 | 白泽 (Baize) — iOS 本地编程智能体 |
| 类比 | 像 Claude Code / Codex，但跑在 iPad Pro M1 本地 |
| 运行环境 | iPad Pro 2021 M1, iOS 16.6.1, 通过 TrollStore 免签安装 |
| 构建方式 | GitHub Actions CI (macos-15 runner) → 编译 IPA → ldid fakesign → 下载安装 |
| 技术栈 | Swift 6 + SwiftUI | libgit2 C API | nodejs-mobile (--jitless) | CPython 3.13 | ios_system | Monaco Editor (WKWebView) |
| GitHub 仓库 | https://github.com/Da-AiXZ/BaiZe |
| 分支 | main |
| 本地路径 | `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize` |
| GitHub Token | `<GH_TOKEN见memory或问用户>` |
| 最新已提交 | `72376b6` (2026-06-21) |
| 工作区状态 | 47 文件未提交（T01-T04 重构代码） |

### Token 获取方式

- 方式 1: 问用户要（用户知道 token）
- 方式 2: 查看本地工作区记忆文件 `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\.workbuddy\memory\MEMORY.md`
- 方式 3: 查看 git remote URL — `git -C "C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize" remote -v` 输出里包含 token
- ⚠️ **这个 token 已暴露在对话历史中，建议用户撤销重新生成**
- ⚠️ **Token 不能写进 commit**（GitHub secret scanning 会拒绝 push）

---

## 8. iOS 特有约束（CRITICAL）

1. **禁止 `fork()`** — 用 `posix_spawn` 替代
2. **禁止 JIT** — Node.js 必须用 `--jitless` 模式
3. **TrollStore 分发** — 需要 `platform-application` + `no-sandbox` entitlements
4. **spawned binary 必须在 App Bundle 内** 且已签名
5. **无沙盒** — TrollStore 授予完整文件系统访问
6. **Swift 6 严格模式** — Xcode 16 默认启用，actor 隔离规则更严，所有 async 调用必须显式 `await`
7. **`let` 不可二次初始化** — 已初始化的 `let` 属性不能再在 init 里赋值
8. **`POSIX_SPAWN_SETPGROUP`** — macOS/iOS 上是 `Int16` 类型，需要显式 cast
9. **`pclose` / `WIFEXITED`** — iOS 不可用，用 `fclose` + 手动解析 wait status
10. **Info.plist 必须有 `UIFileSharingEnabled`** — 否则写 `/var/mobile/Documents/` 报权限错

### Swift 6 actor 隔离血泪教训（前任经验）

**SwiftUI View struct 中如果有方法调用 @MainActor 的依赖（如 AppState），最干净的方案是给整个 struct 加 @MainActor**，而不是给单个方法加或用 Task 包裹。

前任修 Bug 1 时经历 3 轮 CI 失败才搞定：
- CI #114 ❌ FileTreeNode 方法调用 @MainActor 的 appState
- CI #115 ❌ 给方法加 @MainActor → 闭包调用处报错
- CI #116 ❌ 用 Task { @MainActor in } 包裹 → 方法内部调用仍报错
- CI #117 ✅ 给整个 FileTreeNode struct 加 @MainActor

---

## 9. CI/CD 管道速查

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
- 签名: ldid fakesign
- IPA 输出: `output/Baize.ipa`
- 部署目标: iOS 16.0

### GitHub CLI / API 使用方法（Windows Git Bash）

```bash
# 设置 token
export GH_TOKEN="<GH_TOKEN见memory或问用户>"

# 查看最近 CI 运行
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

# 搜索编译错误
grep -E "❌|error:" /tmp/ci-logs.txt | grep -v "didFail\|withError\|Build Status" | head -20
```

### 前台盯 CI（用户要求不用后台）
```bash
RUN_ID=<新提交的run_id>
for i in $(seq 1 20); do
  STATUS=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/${RUN_ID}" \
    | python -c "import json,sys; r=json.load(sys.stdin); print(f\"{r['status']}/{r['conclusion'] or 'None'}\")")
  echo "[$(date +%H:%M:%S) 第${i}次] $STATUS"
  case "$STATUS" in
    completed/success) echo "✅ 成功"; break;;
    completed/failure) echo "❌ 失败"; break;;
  esac
  sleep 45
done
```

---

## 10. 项目文件结构（重构后）

```
baize/
├── .github/workflows/build.yml    ← CI/CD 流水线
├── project.yml                    ← XcodeGen 项目规范
├── scripts/                       ← 构建脚本
├── Baize/
│   └── Baize/
│       ├── App/
│       │   └── BaizeApp.swift     ← @main 入口 + DI 容器（已扩展注入新服务）
│       ├── Agent/                 ← Agent 核心（大幅扩展）
│       │   ├── AgentLoop.swift    ← actor 主循环（新增 PlanMode 拦截/Skill 匹配/Memory 提取）
│       │   ├── AgentEvent.swift   ← 事件枚举（新增 14 case）
│       │   ├── Tool.swift         ← Tool 协议（扩展 permissionLevel/category/needsPermission）
│       │   ├── ToolRegistry.swift ← actor 工具注册表（24 工具）
│       │   ├── PermissionEngine.swift ← 权限引擎（新增 needsPermission）
│       │   ├── ContextManager.swift ← 上下文管理（新增 Memory 注入）
│       │   ├── ProjectContext.swift
│       │   ├── ConversationStore.swift
│       │   ├── Message.swift
│       │   ├── ToolCall.swift
│       │   ├── ToolResult.swift
│       │   ├── Skills/            ← 🆕 Skills 系统（3 文件）
│       │   ├── Memory/            ← 🆕 Memory 系统（3 文件）
│       │   ├── Commands/          ← 🆕 Slash Commands（2 文件）
│       │   ├── PlanMode/          ← 🆕 PlanMode 状态机（1 文件）
│       │   ├── WebSearch/         ← 🆕 WebSearch 多引擎（5 文件）
│       │   ├── SubAgent/          ← 🆕 Sub-agent 系统（4 文件，R2）
│       │   └── MCP/               ← 🆕 MCP 远程集成（3 文件，R2）
│       ├── Infrastructure/        ← 基础设施（不变）
│       ├── Tools/                 ← 工具（10 现有 + 14 新增 = 24）
│       │   ├── ReadFileTool.swift ... RunPythonTool.swift  ← 现有 10 个
│       │   ├── TodoWriteTool.swift         ← 🆕 R1
│       │   ├── AskUserQuestionTool.swift   ← 🆕 R1
│       │   ├── WebFetchTool.swift          ← 🆕 R1
│       │   ├── WebSearchTool.swift         ← 🆕 R1
│       │   ├── EnterPlanModeTool.swift     ← 🆕 R1
│       │   ├── ExitPlanModeTool.swift      ← 🆕 R1
│       │   ├── SkillTool.swift             ← 🆕 R1
│       │   ├── AgentTool.swift             ← 🆕 R2
│       │   ├── TaskCreateTool.swift        ← 🆕 R2
│       │   ├── TaskUpdateTool.swift        ← 🆕 R2
│       │   ├── TaskListTool.swift          ← 🆕 R2
│       │   ├── TaskGetTool.swift           ← 🆕 R2
│       │   ├── SendMessageTool.swift       ← 🆕 R2
│       │   └── MCPTool.swift               ← 🆕 R2
│       ├── Services/              ← 服务（不变）
│       ├── ViewModels/
│       ├── Views/
│       │   ├── ContentView.swift  ← 重构：5 Tab → 聊天+工作台
│       │   ├── Chat/              ← 聊天视图（ChatView 新增 14 case 处理）
│       │   ├── Editor/            ← 简化为只读+diff
│       │   ├── Git/               ← 砍 4 视图，留 3 只读
│       │   ├── Terminal/          ← 简化为命令输出查看
│       │   ├── Dashboard/         ← 简化为侧栏统计
│       │   ├── Settings/          ← 新增 3 设置页
│       │   ├── Sidebar/
│       │   ├── Workbench/         ← 🆕 工作台侧栏（5 文件）
│       │   └── Dialogs/           ← 🆕 弹窗（2 文件）
│       ├── Models/
│       ├── Utils/
│       └── Resources/
│           └── skills/            ← 🆕 8 个内置 SKILL.md
├── BaizeTests/
├── docs/
├── PRD_白泽重构_v1.md             ← 🆕 PRD（在 D:/111/.../）
├── ARCH_白泽重构_v1.md            ← 🆕 架构文档（在 D:/111/.../）
└── BAIZE_HANDOFF_V13.md           ← 本文档
```

---

## 11. 核心架构速览（重构后）

### 三层架构
```
UI (SwiftUI) → Business (Agent Services) → Infrastructure (Platform)
```

### Agent Loop 流程（扩展后）
```
用户输入 → CommandRegistry.parse（/命令?）→ SkillRegistry.matchSkill（触发词?）
→ AgentLoop(actor) → LLM reasoning (SSE流式)
  → PlanMode 检查（计划模式拦截写操作）
  → tool_call → PermissionEngine.evaluate → ToolRegistry → 执行 → 结果
  → emitSpecialToolEvents（发射特殊事件）
  → 循环直到 LLM 返回 finish
→ MemoryExtractor.extractAndStore（异步提取记忆，不阻塞）
```

### 并发模型（全部 Swift Actor）
- `AgentLoop`: actor — 主循环
- `ToolRegistry`: actor — 工具注册/查找
- `APIGateway`: actor — LLM API 调用
- `PermissionEngine`: actor — 权限决策
- `ConversationStore`: actor — 对话持久化
- `ProjectRegistry`: actor — 项目注册表
- `GitService`: actor — Git 操作
- `UsageTracker`: actor — 用量统计
- `TerminalHistoryStore`: actor — 终端历史
- `SkillRegistry`: actor — 🆕 技能注册表
- `MemoryStore`: actor — 🆕 记忆存储
- `CommandRegistry`: actor — 🆕 命令注册表
- `PlanModeState`: actor — 🆕 计划模式状态
- `TaskList`: actor — 🆕 任务列表
- `TeamCoordinator`: actor — 🆕 团队协调
- `MCPManager`: actor — 🆕 MCP 连接管理

### 24 个内置工具

| 类别 | 工具 |
|------|------|
| fileSystem | ReadFile / WriteFile / EditFile / DeleteFile / ListDirectory / SearchFiles / SearchContent |
| execution | ExecuteCommand / RunNode / RunPython |
| planning | TodoWrite / EnterPlanMode / ExitPlanMode |
| web | WebFetch / WebSearch |
| agent | AskUserQuestion / AgentTool / SendMessage |
| task | TaskCreate / TaskUpdate / TaskList / TaskGet |
| skill | SkillTool |
| mcp | MCPTool |

---

## 12. 真机测试进度

### 已完成（v12 时）
- 第 1-2 层：启动+聊天+文件操作 ✅（6 Bug 已修）
- 第 3 层：代码执行 ✅（RunPython/RunNode 跑通，发现 2 新 Bug 未修）

### 待测试（重构后需重测）
- 第 3 层：代码执行（重构后重测）
- 第 4 层：Git 操作（AI 自主 Git，验证 Bug 4 修复）
- 第 5 层：多项目管理
- 第 6 层：聊天增强（折叠/导出）
- 第 7 层：多模型
- 第 8 层：Monaco 编辑器
- 🆕 第 9 层：Skills 系统（触发词匹配/技能执行）
- 🆕 第 10 层：Memory 系统（自动提取/注入）
- 🆕 第 11 层：PlanMode（计划/审批/执行）
- 🆕 第 12 层：Slash Commands（10 命令）
- 🆕 第 13 层：WebSearch（多引擎）
- 🆕 第 14 层：Sub-agent（spawn 子 agent）
- 🆕 第 15 层：MCP 远程（接入 1 个 MCP server）

### 未修复的 Bug（重构前发现）
| # | Bug | 优先级 | 状态 |
|---|-----|--------|------|
| 7 | 工具执行后参数显示"无"，切 Tab 才刷新 | P1 | 未修（重构后可能已解决，需验证） |
| 8 | 终端历史重启后清空（Bug 3 修复回归） | P1 | 未修 |

---

## 13. 关键技术决策日志

| 编号 | 决策 | 理由 |
|------|------|------|
| Q1 | 嵌入主进程（不用 App Extension） | iOS 不支持 child_process，白泽用 posix_spawn |
| Q2 | Monaco Editor via WKWebView | 参考 CodeApp 架构 |
| Q3 | Python 最小集 + 按需 pip | Phase 1 只带最小 Python |
| Q4 | `/var/mobile/Documents/Baize/` 默认路径 | iOS 标准文档目录，TrollStore no-sandbox 可访问 |
| Q5 | 多 Provider 支持 | OpenAI/Anthropic/OpenRouter/Custom |
| Q6 | 简单弹窗权限 → 扩展为 Tool.needsPermission | R1 重构 |
| 2B | XcodeGen 替代 SPM library target | 统一管理依赖，CI 友好 |
| Bug1 | 给 FileTreeNode struct 加 @MainActor | SwiftUI View 调用 @MainActor 依赖最干净的方案 |
| R1-1 | Tool 协议用 protocol extension 默认值 | 现有 10 工具零改动编译通过 |
| R1-2 | ToolExecutionContext 新增属性全可选 | 现有工具 execute 不受影响 |
| R1-3 | ToolPermissionDecision 避免命名冲突 | PermissionEngine 已有 PermissionDecision struct |
| R1-4 | WebSearchResult 避免命名冲突 | FileSystemService 已有 SearchResult |
| R2-1 | Sub-agent 不需 fork | 创建新 AgentLoop actor 实例，同进程并发 |
| R2-2 | 子 agent 共享 ToolRegistry + 独立 PermissionEngine(.plan) | 仅只读工具 |
| R2-3 | MCP 远程用 URLSession + JSON-RPC 2.0 | 不复用 SSEStream（MCP 用 POST） |
| R3-1 | ContentView 横屏 NavigationSplitView + 竖屏 TabView | horizontalSizeClass 判断 |
| R3-2 | 删 4 Git 视图，留 3 只读 | 决策 6：砍手动留只读 |
| Q7 | MCP 本地 posix_spawn+pipe 已验证可行 | 白泽 PythonSpawnStrategy 已有先例 |
| Q8 | 向量记忆推荐远程嵌入 API | onnxruntime-ios 增 50-80MB 不可接受 |

---

## 14. 用户偏好（CRITICAL — 和这个用户协作时注意）

> **用户原话（v12 交接文档记录）**：
> - "直来直去，别废话"
> - "不懂别装懂，不会的就去搜"
> - "不要偷工减料 — 每个阶段走标准化流程，QA 检测到 Critical 比做 demo 更重要"
> - "大布局 + 丰富元素"
> - "前台盯 CI — 用前台盯着，不要用后台监控"
> - "积分有限 — 高效，不要浪费轮次，能一次搞定别分两次"

### 本次会话新增的用户偏好

- **用户是视觉导向的**：方案要有层次感，给方案文档时要 `present_files` 让用户能直接看
- **用户会给大量参考材料**：cc-haha / 26 个 Agent 框架 / Operit，要真正读完理解后再设计
- **用户会叫停走歪的项目**：发现方向错了要敢于重新设计，不要硬着头皮继续
- **用户坚持 iOS 平台**：给桌面端方案会被否决，要基于 iOS 约束设计
- **用户以白泽为基底**：不推倒重来，增量重构
- **用户要求架构师验证 iOS 可行性**：不要设计出没法实现的东西拖慢项目
- **用户对标 Claude Code/Codex**：目标是 iOS 端一样强的全能 Agent

---

## 15. 团队协作模式（软件公司 SOP）

本项目使用多智能体团队协作，主理人齐活林（交付总监）协调：

| 成员 | 姓名 | 职责 |
|------|------|------|
| 产品经理 | 许清楚 (Xu) | 创建 PRD 或市场/竞品研究 |
| 架构师 | 高见远 (Gao) | 系统架构 + 任务分解 + iOS 可行性验证 |
| 工程师 | 寇豆码 (Kou) | 批量编写代码 |
| QA工程师 | 严过关 (Yan) | 测试验证 |

### 工作流路由
- **快速模式** (≤10 文件): TeamCreate → 工程师(全部代码) → QA
- **BugFix 快捷路径** (明确 Bug): TeamCreate → 工程师(定位+修复) → QA(回归)
- **标准 SOP** (>10 文件): PRD → 架构 → 代码 → QA

### 子任务命名（CRITICAL）
调度成员时 `name` 和 `subagent_type` 都传 Agent ID：
- `name: "software-engineer", subagent_type: "software-engineer"`
- `name: "software-qa-engineer", subagent_type: "software-qa-engineer"`

### 本次会话的团队
- 团队名：`software-baize-refactor`
- 状态：T01-T04 完成，QA 未完成
- ⚠️ **下一位 AI 需要先 shutdown 现有团队成员，或直接 TeamDelete 后重建**

---

## 16. 常见坑和注意事项

1. **`gh` CLI 路径**: Windows 下可能没有 `gh`，用 `curl + GitHub API` 代替
2. **SSH 子模块**: ios_system 的 wasm3 子模块用 SSH URL，需要 `git config --global url."https://github.com/".insteadOf "git@github.com:"`
3. **xcpretty 是 Ruby Gem**: 不是 Homebrew formula，用 `gem install`
4. **macOS Runner**: 必须是 `macos-15`（Xcode 16），`macos-14` 的 Xcode 15 不认 project format 77
5. **CRLF 警告**: 不用管，是 Windows Git 的自动换行转换
6. **Information.plist 的 UILaunchScreen**: iOS 14+ 用字典替代 storyboard
7. **IPA 签名**: 用 `ldid` 而不是 Apple 证书 — 对 `.app/AppName` 可执行文件签名，不是整个 `.ipa`
8. **git 身份**: 新克隆的仓库需 `git config user.email` + `git config user.name` 才能 commit
9. **SwiftUI View + @MainActor**: View struct 中有方法调用 @MainActor 依赖时，给整个 struct 加 @MainActor
10. **Token 不写明文**: GitHub secret scanning 会拒绝含明文 token 的 push
11. **命名冲突**: 新增类型前先 grep 检查是否已有同名（本次遇到 PermissionDecision 和 SearchResult 两个冲突）
12. **占位替换**: T01 用占位空 actor，后续任务必须替换为真实实现并删除占位定义

---

## 17. 快速参考命令

```bash
# 进入项目
cd "C:/Users/netease/WorkBuddy/2026-06-21-18-14-27/baize"

# 设置 token
export GH_TOKEN="<GH_TOKEN见memory或问用户>"

# 查看状态
git status
git log --oneline -5

# 推送到 GitHub
git push origin main

# 设置 git 身份（新克隆需要）
git config user.email "baize-dev@daiaixz.local"
git config user.name "Baize Dev"

# 查看 CI
curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs?per_page=3" \
  | python -c "import json,sys; [print(f\"#{r['run_number']} | {r['status']}/{r['conclusion']} | {r['head_sha'][:7]}\") for r in json.load(sys.stdin)['workflow_runs']]"

# 下载最新 IPA artifact
# 去网页: https://github.com/Da-AiXZ/BaiZe/actions
# 找到成功的 run，拉到底部 Artifacts，点 Baize-IPA 下载
```

---

## 18. 方案文档位置（本次会话产出）

所有方案文档在当前 workspace `D:\111\2026-06-21-22-21-21\`：

| 文档 | 路径 | 说明 |
|------|------|------|
| v1 方案 | `白泽重构方案_v1.md` | 走歪诊断 + 重构方向 |
| v2 决策 | `白泽重构方案_v2_6决策.md` | 基于 Operit 研究的 6 个决策 |
| PRD | `PRD_白泽重构_v1.md` | 正式增量 PRD |
| 架构文档 | `ARCH_白泽重构_v1.md` | 系统设计 + iOS 可行性验证 |
| 类图 | `class-diagram.mermaid` | 数据结构类图 |
| 时序图 | `sequence-diagram.mermaid` | 5 个流程时序图 |
| 本交接文档 | `BAIZE_HANDOFF_V13.md` | 本文档 |

⚠️ 这些文档在 workspace 不在项目目录，下一位 AI 可能需要先找到它们。建议复制到项目目录或让用户指路。

---

## 19. 前任 AI 的总结

```
我（这一任 AI）的工作：
- 接手 v12 交接文档，引导用户真机测试第 3-4 层
- 用户叫停："项目走歪了，和 Claude Code 差好多"
- 研究用户提供的 cc-haha + 26 个 Agent 框架 + Operit 源码
- 输出 v1 方案 + v2 决策（6 个决策）
- 拉团队走标准 SOP：PRD → 架构（含 iOS 可行性验证）→ 代码（T01-T04）
- T01-T04 全部 IS_PASS: YES，但 QA 未完成（用户积分用尽叫停）
- 47 个文件未提交

你（接手的 AI）只需要：
1. 读完这份文档
2. QA 验证 T01-T04 代码（不要盲信工程师的 IS_PASS）
3. 修 Bug → commit → push → 前台盯 CI
4. CI 通过后引导用户真机测试
5. 收集新 Bug → BugFix 快捷路径修复
6. 保持 CI 绿色
7. 后续做 T05（R4+R5 高级）

核心原则（血泪经验，务必遵守）：

1. **用户积分金贵** — 别浪费轮次，能一次搞定别分两次。前台盯 CI 别用后台，编译失败直接改，改完直接 push，别问"要不要继续"。

2. **不懂别装懂** — 不会的就去 Web 搜索验证，有需求疑问的就问用户，别自己瞎猜。用户最讨厌装懂。

3. **不要偷工减料** — 每个阶段走标准化流程，QA 检测到 Critical 比做 demo 更重要。

4. **Swift 6 actor 隔离是地雷** — 任何 SwiftUI View 调用 @MainActor 依赖（AppState/GitViewModel 等），直接给整个 struct 加 @MainActor，别试单个方法加或 Task 包裹。

5. **Token 不能写进 commit** — GitHub secret scanning 会拒绝含明文 token 的 push。Token 存在本地记忆文件和 git remote URL 里，自己去读，别复制到代码或文档里。

6. **用户说话直来直去，你也别废话** — 发现什么问题直接说，别铺垫。方案要给全，别挤牙膏。

7. **iOS 可行性必须验证** — 用户特别强调"不要设计出没法实现的东西拖慢项目"。每个设计点都要标注 iOS 可行性，⚠️ 的给验证方案，❌ 的给替代方案。

8. **以白泽为基底，不推倒重来** — 用户明确要求增量重构。现有 AgentLoop/ContextManager/PermissionEngine/APIGateway/libgit2/nodejs-mobile/CPython/Monaco Bridge 全部保留。

9. **坚持 iOS 平台** — 用户明确不要桌面端。给桌面端方案会被否决。

10. **对标 Claude Code/Codex** — 目标是 iOS 端一样强的全能 Agent，不是 iOS 编程工具。

祝顺利 🔧
```

---

## 20. 安全提醒（CRITICAL）

⚠️ **GitHub Token `<GH_TOKEN见memory或问用户>` 已在对话历史中明文暴露**。

**强烈建议**：
1. 让用户去 GitHub Settings → Developer settings → Personal access tokens 撤销这个 token
2. 生成新 token
3. 通过环境变量或更安全的方式传递，不要再明文贴出

---

*生成时间: 2026-06-22 01:15 | 项目: 白泽 Baize iOS 本地编程智能体 | 阶段: 重构 R1+R2+R3 代码完成，待 QA+CI+真机测试 | 版本: v13*
