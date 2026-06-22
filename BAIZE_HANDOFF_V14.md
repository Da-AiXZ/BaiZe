# 白泽 (Baize) — AI 继承者交接文档 v14

> **给下一位 AI 的话**：这份文档就是你的"记忆"。读完 ≈ 你跟着我从头干到了这里。
> 严格按文档指示操作，不要自己瞎猜。**不确定的就去核验、查清，不要盲猜。**
>
> **生成时间**: 2026-06-22 12:50 | **版本**: v14（替代 v13，因完成真机测试 + 发现 25 个 Bug + 正在修复中）
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 接手 v13 → QA 验证 → CI 编译修复（6 轮）→ 全量代码审查 → 配置备份/恢复 → iPad 入口修复 → 真机测试 → 收集 25 个 Bug → 正在按优先级修复

---

## 0. TL;DR — 最重要的事先说

1. **项目位置**: `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe (分支 `main`)
3. **最新 commit**: `942c560` (2026-06-22，iPad 入口右侧栏修复)
4. **最新 CI**: #126 ✅ 成功，IPA 可下载
5. **当前状态**: 用户已完成第一轮真机测试，反馈 25 个 Bug，正在按优先级修复中
6. **积分警告**: 用户积分可能随时耗尽，每修完一个 Bug 就更新本文档的"已修"部分，防止中断后状态丢失
7. **下一步首要任务**: 继续按优先级修 Bug（P0 先修），修完 commit + push + 盯 CI

---

## 1. 本次会话发生了什么（时间线）

### 阶段一：接手 + QA 验证 + CI 编译修复（01:53 - 03:00）

- 接手 v13 交接文档，确认项目状态（T01-T04 重构代码 47 文件未提交）
- 创建团队 `software-baize-qa`，QA 严过关独立验证
- QA 发现 3 个编译错误（重复属性 / 多余 try / 非可选 guard let）→ 工程师修复 → QA 回归 PASS
- 首次 commit `9b212c8` → CI #118 失败（20 个 Swift 6 编译错误）
- 工程师批量修复 20 个错误 `1015435` → CI #119 失败（ContentView any View）
- 主理人自修 ContentView（Group 包裹）`9a83c04` → CI #120 失败（WorkbenchSidebar @escaping）
- 3 轮修 WorkbenchSidebar @escaping 语法 → `ba1c730` → CI #123 ✅ 成功

### 阶段二：全量代码审查 + 配置备份（03:00 - 04:30）

- 用户反馈"设置整没了"
- QA 全量审查 125 文件：设置丢失 = TrollStore 重装清数据（非代码 Bug）
- 发现 14 个其他 Bug → 工程师全修 `a4212f8` → CI #124 ✅
- 用户反馈"还是没有"
- 深挖根因：`BaizePath.globalConfig` 路径已定义但从未实现备份/恢复
- 实现 ConfigBackupService（328 行）`300886e` → CI #125 ✅

### 阶段三：iPad 入口修复（04:30 - 09:00）

- 用户反馈"整个 tabview 都没了"
- **根因发现**：iPad 横竖屏 `horizontalSizeClass` 都是 `.regular`，TabView 分支（含设置/首页/工作台）永不执行
- **⚠️ 教训**：主理人一开始没核验 iPad size class 规则就瞎猜"竖屏有 TabView"，被用户痛骂"针眼说瞎话"。用户明确要求加偏好"不要盲猜，不确定的就去核验"
- 用户拍板方案 B：右侧栏 + 三个 sheet
- 工程师修复 `942c560` → CI #126 ✅

### 阶段四：真机测试 + 25 个 Bug 反馈（09:00 - 12:46）

- 用户下载 CI #126 IPA 安装测试
- 反馈 25 个 Bug（见第 4 节）
- 用户要求：先写交接文档（防中断）→ 再按优先级修
- **当前正在进行**：写本交接文档 + 准备修 P0 Bug

---

## 2. 用户测试反馈 25 个问题 + 优先级排序

### P0 — 阻塞核心（必须先修，5 个）

| # | 问题描述 | 根因分析 | 修复方向 |
|---|---------|---------|---------|
| 7 | **创建项目权限失败**："你没有将文件Baize储存到Documents的权限" | FileManager.default 在 TrollStore 环境下可能有沙盒残留限制；或 entitlements 缺少文件系统写入权限 | 核验 entitlements + FileManager 路径，可能需要用 posix_spawn mkdir 或确认 no-sandbox entitlement |
| 5/6 | **Git 命令沙箱不可用**：AI 执行 `git status` 报错"git 命令在 iOS 沙箱中不可用" | ExecuteCommandTool 走 ios_system 执行 git，但 iOS 无 git 二进制；白泽有 GitService(libgit2) 但 AI 不知道用 | 需要 GitTool 工具封装 GitService，让 AI 调用 GitTool 而非 ExecuteCommand 执行 git |
| 15/16/17 | **PlanMode 只进不出 + 莫名被拒 + 无审批窗**：进入计划模式后无法退出，提交计划说"用户拒绝"但没弹窗，创建文件说只读 | PlanModeState 的审批流程 + ExitPlanModeTool 的实现有逻辑错误；PlanApprovalView 可能没正确绑定 | 核验 PlanModeState actor + ExitPlanModeTool + PlanApprovalView 的完整数据流 |
| 24 | **子 agent 被拒 + 绕过模式仍询问**：AgentTool 被拒"计划模式禁止写操作"，切绕过模式依旧询问权限 | PermissionEngine 的 isToolReadOnly 判断有误 + 绕过模式没正确跳过权限 | 核验 PermissionEngine.evaluate 逻辑 + bypass 模式实现 |
| 3(部分) | **工具参数显示"无" + 内容省略号**：工具调用下显示"无参数"，切对话才显示；长内容省略号 | ToolCallView 渲染逻辑 + 工具结果截断逻辑 | 核验 ToolCallView + ChatView 的工具调用显示 + ToolResultTruncator |

### P1 — 严重体验（9 个）

| # | 问题描述 | 根因分析 | 修复方向 |
|---|---------|---------|---------|
| 1 | **流式输出不流畅**：一下出现很多字，不是逐字 | SSE 流式解析或 UI 刷新批次问题 | 核验 SSEStream + StreamingTextBuffer + ChatView 的刷新逻辑 |
| 9 | **sheet 黑屏**：对话点出弹出的 sheet 是黑屏 | sheet 内容视图可能缺 @MainActor 或初始化失败 | 核验所有 sheet 的视图初始化 |
| 13 | **Skills 不可用**：设置里没有 skill，AI 不触发 skill，卡在 enter_plan_mode | SkillRegistry 没加载 bundled skills；或 SkillTool 实现有误；AI 调 enter_plan_mode 而非 skill | 核验 SkillRegistry.loadBundledSkills + SkillTool.execute + matchSkill 逻辑 |
| 14 | **Memory 不自动提取**：没有 memory 文件夹，一条记忆都没提取 | MemoryExtractor 没执行；或目录创建失败静默跳过 | 核验 MemoryExtractor.extractAndStore + MemoryStore 的目录创建 |
| 18 | **AskUserQuestion 异常**：没选择就停下，选好发送没反应，AI 不知道选择内容 | AskUserQuestionTool + AskUserQuestionView 的用户回答回传流程断裂 | 核验 AskUserQuestionView 的选择回传 + AgentLoop 的事件处理 |
| 20 | **Slash 无补全**：输入 / 不弹建议，部分命令无响应 | ChatInputView 的命令检测逻辑 | 核验 ChatInputView 的 / 检测 + CommandRegistry.parse |
| 22 | **搜索引擎切换不持久**：切了 DuckDuckGo 保存了，退出还是 Tavily | SearchEngineSettingsView 的保存逻辑 + WebSearchFactory 的读取逻辑 | 核验搜索引擎选择的 UserDefaults 持久化 |
| 11 | **Monaco 编辑器问题**：可编辑但不保存、不实时更新、关不掉文件、打开其他文件不切换 | EditorContainerView + EditorTabBar 的文件管理逻辑 | 核验 EditorState + EditorContainerView 的文件切换/关闭/保存 |
| 4 | **终端历史重启清空** | TerminalHistoryStore 持久化逻辑 | 核验 TerminalHistoryStore 的文件读写 |

### P2 — 体验问题（5 个）

| # | 问题描述 | 根因分析 | 修复方向 |
|---|---------|---------|---------|
| 8 | **折叠逻辑有问题**：新消息自动折叠，折叠不全 | ChatMessageList 的折叠算法 | 核验 ChatMessageList 的折叠阈值 |
| 12 | **Diff 视图显示"无差异"**：工作台代码差异点开文件没显示 diff | DiffViewer 的 diff 生成逻辑 | 核验 DiffViewer 的文件对比 |
| 21 | **搜索理解差**：搜 Claude 最新模型，AI 说 op4.8/fable | AI 模型理解问题 + 搜索结果质量 | 改进 WebSearch 的 prompt 或结果处理 |
| 23 | **搜索质量差**：野鸡平台数据 | WebSearch 结果来源 | Tavily/Bing/Google 的结果过滤 |
| 2 | **搜索大小写敏感**：搜 hello 搜不到 Hello | SearchContentTool 的搜索逻辑 | 改为大小写不敏感搜索 |

### 无需修复（2 个）
- 第 10 个：模型切换正常 ✅
- 第 19 个：只读工具正常 ✅

---

## 3. 修复进度跟踪（实时更新）

> **⚠️ 每修完一个 Bug，立即更新此表 + commit + push，防止积分耗尽中断**

### 已修（5/25）— commit 5d63d75, CI #127 ✅
- ✅ P0-1 Bug #7 创建项目权限：ensureDirectoryExists 添加 posix_spawn mkdir -p 回退
- ✅ P0-2 Bug #5-6 Git沙箱：ExecuteCommandTool 拦截 git 命令转给 GitService(libgit2)
- ✅ P0-3 Bug #15-17 PlanMode：执行 exit_plan_mode 前发射 .planApprovalRequested + approve/reject 后 reset idle
- ✅ P0-4 Bug #24 子agent权限：AgentTool .plan→.default + bypass 跳过 PlanMode 拦截
- ✅ P0-5 Bug #3 工具参数显示：updateToolCallStatus 更新 toolCall + 原始 JSON 回退 + 截断 300→2000

### 正在修
*暂无（刚写完交接文档，准备开始 P0）*

### 待修（25 个）
- P0: #7 创建项目权限 / #5-6 Git沙箱 / #15-17 PlanMode / #24 子agent权限 / #3 工具参数显示
- P1: #1 流式 / #9 sheet黑屏 / #13 Skills / #14 Memory / #18 AskUser / #20 Slash / #22 搜索引擎 / #11 Monaco / #4 终端历史
- P2: #8 折叠 / #12 Diff / #21 搜索理解 / #23 搜索质量 / #2 大小写

---

## 4. 项目身份与仓库

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
| GitHub Token | `<见 git remote 或问用户，不写明文>`（⚠️ 已暴露建议撤销） |
| 最新 commit | `942c560` (2026-06-22) |
| 最新 CI | #126 ✅ 成功 |

### Token 获取方式
- 方式 1: `git -C "C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize" remote -v` 输出里包含 token
- 方式 2: 问用户要
- ⚠️ Token 不能写进 commit（GitHub secret scanning 会拒绝 push）
- ⚠️ 这个 token 已暴露在对话历史中，建议用户撤销重新生成

---

## 5. 重构方案核心（必读，来自 v13）

### 走歪诊断（重构前）

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
1. WebSearch: 多搜索引擎架构，默认 Tavily，可选 Bing/Google/DuckDuckGo
2. MCP 优先级: 从 R4 提前到 R2
3. 交互重构时机: R1 与 R3 并行（独立分支）
4. Skills 内置清单: P0 内置 8 个（commit-push/review/debug-error/fix-bug/refactor/test-gen/explain-code/new-feature）
5. Memory 自动提取: 开启，三阶段递进（R1 文件+关键词 → R4 打分+SQLite → R5 向量）
6. Git Tab 处置: 砍手动操作，保留只读查看 + 工作台侧栏

---

## 6. 架构设计要点

### iOS 可行性验证结论（来自 v13 架构师）
- ✅ 完全可行：28 项（93%）
- ⚠️ 需关注：2 项（MCP 本地 posix_spawn+pipe 已验证可行 / 向量记忆推荐远程嵌入 API）
- ❌ 不可行：0 项

### 零新增第三方依赖
R1/R2/R3 不引入任何新 SPM 包。R4 链接系统自带 libsqlite3.tbd。R5 用远程嵌入 API。

### 关键架构决策
1. Tool 协议扩展用 protocol extension 默认值：现有 10 个工具零改动编译通过
2. ToolExecutionContext 新增属性全部可选（?）：现有工具 execute 方法不受影响
3. AgentEvent 新增 14 个 case，全部保持 @unchecked Sendable
4. Skills 复用 ProjectContext.parseBaizeMD() 的 YAML frontmatter 解析模式
5. Memory 自动提取复用 ContextManager.generateSummary() 的 LLM 调用 + 超时降级模式
6. PlanMode 与现有 PermissionMode.plan 协同
7. Sub-agent 不需 fork：创建新 AgentLoop actor 实例，同进程内并发运行

### 三层架构
```
UI (SwiftUI) → Business (Agent Services) → Infrastructure (Platform)
```

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

### 并发模型（全部 Swift Actor）
AgentLoop / ToolRegistry / APIGateway / PermissionEngine / ConversationStore / ProjectRegistry / GitService / UsageTracker / TerminalHistoryStore / SkillRegistry / MemoryStore / CommandRegistry / PlanModeState / TaskList / TeamCoordinator / MCPManager / ConfigBackupService

---

## 7. iOS 特有约束（CRITICAL）

1. **禁止 `fork()`** — 用 `posix_spawn` 替代
2. **禁止 JIT** — Node.js 必须用 `--jitless` 模式（Bug #3 已修，NodeRuntimeEngine.swift 已加 --jitless）
3. **TrollStore 分发** — 需要 `platform-application` + `no-sandbox` entitlements
4. **spawned binary 必须在 App Bundle 内** 且已签名
5. **无沙盒** — TrollStore 授予完整文件系统访问（但 FileManager.default 可能仍有残留限制 — 见 Bug #7）
6. **Swift 6 严格模式** — Xcode 16 默认启用，actor 隔离规则更严，所有 async 调用必须显式 `await`
7. **`let` 不可二次初始化** — 已初始化的 `let` 属性不能再在 init 里赋值
8. **`POSIX_SPAWN_SETPGROUP`** — macOS/iOS 上是 `Int16` 类型，需要显式 cast
9. **`pclose` / `WIFEXITED`** — iOS 不可用，用 `fclose` + 手动解析 wait status
10. **Info.plist 必须有 `UIFileSharingEnabled`** — 否则写 `/var/mobile/Documents/` 报权限错
11. **iPad horizontalSizeClass 永远是 .regular** — 横竖屏都是，不能用 size class 判断横竖屏（血的教训，见阶段三）

### Swift 6 actor 隔离血泪教训
- SwiftUI View struct 中如果有方法调用 @MainActor 的依赖（如 AppState），给整个 struct 加 @MainActor
- StateObject autoclosure 不支持 async/Task，需移到 init 方法体
- os.Logger 字符串插值需 `String(describing:) + privacy: .public` 避免类型歧义
- `@ViewBuilder` 放参数名前，`@escaping` 放类型标注上，不能混用位置
- if-else + 链式修饰符在 Swift 6 下类型推断退化，用 `Group { }` 包裹

---

## 8. CI/CD 管道速查

### 工作流文件
`.github/workflows/build.yml`

### CI 步骤
```
Checkout → Print Xcode version → Install tools (brew ldid xcodegen + gem xcpretty)
→ Cache SPM → Configure git HTTPS → xcodegen generate → Resolve SPM
→ Download Runtime → xcodebuild archive → build-ipa.sh → verify-ipa.sh
→ Upload IPA artifact
```

### 构建关键参数
- Runner: `macos-15` (Xcode 16.x) — 必须用这个
- SDK: `iphoneos` arch: `arm64`
- 签名: ldid fakesign
- IPA 输出: `output/Baize.ipa`
- 部署目标: iOS 16.0

### GitHub CLI / API 使用方法（Windows Git Bash）
```bash
# 设置 token
export GH_TOKEN="<从 git remote 读取，不写明文>"

# 查看最近 CI 运行
curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs?per_page=5" \
  | python -c "import json,sys; [print(f\"#{r['run_number']} | {r['status']}/{r['conclusion']} | {r['head_sha'][:7]}\") for r in json.load(sys.stdin)['workflow_runs']]"

# 下载失败日志
JOB_ID=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/<RUN_ID>/jobs" \
  | python -c "import json,sys; print(json.load(sys.stdin)['jobs'][0]['id'])")
curl -sL -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/jobs/${JOB_ID}/logs" \
  -o "C:/Users/netease/AppData/Local/Temp/baize-ci/ci-XXX.txt"

# 搜索编译错误
grep -E "❌|error:" "日志路径" | sed 's/.*❌  //' | sort -u
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
  sleep 50
done
```

### 本次会话 CI 历史
| CI # | commit | 结果 | 说明 |
|------|--------|------|------|
| #118 | 9b212c8 | ❌ | 20 个 Swift 6 编译错误 |
| #119 | 1015435 | ❌ | ContentView any View |
| #120 | 9a83c04 | ❌ | WorkbenchSidebar @escaping |
| #121 | 0eeba75 | ❌ | @escaping 位置错 |
| #122 | c48f59c | ❌ | @ViewBuilder 位置错 |
| #123 | ba1c730 | ✅ | 首次成功 |
| #124 | a4212f8 | ✅ | 14 Bug 修复 |
| #125 | 300886e | ✅ | 配置备份/恢复 |
| #126 | 942c560 | ✅ | iPad 入口右侧栏 |

---

## 9. 项目文件结构（重构后）

```
baize/
├── .github/workflows/build.yml    ← CI/CD 流水线
├── project.yml                    ← XcodeGen 项目规范
├── scripts/                       ← 构建脚本
├── Baize/
│   └── Baize/
│       ├── App/BaizeApp.swift     ← @main 入口 + DI 容器
│       ├── Agent/
│       │   ├── AgentLoop.swift    ← actor 主循环
│       │   ├── AgentEvent.swift   ← 事件枚举（14 新 case）
│       │   ├── Tool.swift         ← Tool 协议 + ToolExecutionContext
│       │   ├── ToolRegistry.swift ← actor 工具注册表（24 工具）
│       │   ├── PermissionEngine.swift ← 权限引擎 ⚠️ Bug #24
│       │   ├── ContextManager.swift ← 上下文管理（Memory 注入）
│       │   ├── Skills/            ← Skills 系统 ⚠️ Bug #13
│       │   ├── Memory/            ← Memory 系统 ⚠️ Bug #14
│       │   ├── Commands/          ← Slash Commands ⚠️ Bug #20
│       │   ├── PlanMode/          ← PlanMode 状态机 ⚠️ Bug #15-17
│       │   ├── WebSearch/         ← WebSearch 多引擎
│       │   ├── SubAgent/          ← Sub-agent 系统 ⚠️ Bug #24
│       │   └── MCP/               ← MCP 远程集成
│       ├── Infrastructure/
│       │   ├── NodeRuntimeEngine.swift ← 已加 --jitless ✅
│       │   └── ...
│       ├── Tools/                 ← 24 个工具
│       │   └── ExecuteCommandTool.swift ← ⚠️ Bug #5-6 (git 命令沙箱)
│       ├── Services/
│       │   └── ConfigBackupService.swift ← 🆕 配置备份/恢复
│       ├── Views/
│       │   ├── ContentView.swift  ← R3 重构 + iPad 入口右侧栏
│       │   ├── Dashboard/NewProjectWizard.swift ← ⚠️ Bug #7 创建权限
│       │   ├── Chat/              ← ⚠️ Bug #1 流式 / #3 工具参数 / #8 折叠
│       │   ├── Workbench/         ← 工作台侧栏（5 可折叠区域）
│       │   ├── Settings/          ← 设置（9 项含配置备份）
│       │   └── ...
│       ├── Models/AppState.swift  ← 状态管理
│       └── Utils/Constants.swift  ← 路径/API/Token 常量
├── BaizeTests/
└── BAIZE_HANDOFF_V14.md           ← 本文档
```

---

## 10. 用户偏好（CRITICAL — 和这个用户协作时注意）

> **用户原话（累积自 v12）**：
> - "直来直去，别废话"
> - "不懂别装懂，不会的就去搜"
> - "不要偷工减料 — 每个阶段走标准化流程，QA 检测到 Critical 比做 demo 更重要"
> - "大布局 + 丰富元素"
> - "前台盯 CI — 用前台盯着，不要用后台监控"
> - "积分有限 — 高效，不要浪费轮次，能一次搞定别分两次"

### 本次会话新增的用户偏好（v14）

- **⚠️ 不要盲猜，不确定的就去核验、查清** — 用户原话"不要盲猜，不确定的就去核验，查清，这里说的就是你前面改 tabview 时瞎几把猜"。iPad size class 问题就是因为我没核验就瞎猜"竖屏有 TabView"，被用户痛骂。以后任何不确定的技术判断，先 grep 代码 / 查文档 / 问用户，不要凭感觉下结论。
- **用户是视觉导向的**：方案要有层次感，给方案文档时要 `present_files` 让用户能直接看
- **用户会给大量参考材料**：要真正读完理解后再设计
- **用户会叫停走歪的项目**：发现方向错了要敢于重新设计
- **用户坚持 iOS 平台**：给桌面端方案会被否决
- **用户以白泽为基底**：不推倒重来，增量重构
- **用户要求架构师验证 iOS 可行性**：不要设计出没法实现的东西
- **用户对标 Claude Code/Codex**：目标是 iOS 端一样强的全能 Agent
- **用户积分可能随时耗尽**：每修完一个 Bug 立即更新交接文档 + commit + push，防止中断后状态丢失
- **用户要求交接文档实时更新**：修完什么就在交接文档标记"已修"，目的是下一位 AI 能看懂当前进度

---

## 11. 团队协作模式（软件公司 SOP）

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

---

## 12. 关键技术决策日志（累积）

| 编号 | 决策 | 理由 |
|------|------|------|
| Q1 | 嵌入主进程（不用 App Extension） | iOS 不支持 child_process |
| Q2 | Monaco Editor via WKWebView | 参考 CodeApp 架构 |
| Q3 | Python 最小集 + 按需 pip | Phase 1 只带最小 Python |
| Q4 | `/var/mobile/Documents/Baize/` 默认路径 | iOS 标准文档目录 |
| Q5 | 多 Provider 支持 | OpenAI/Anthropic/OpenRouter/Custom |
| Q6 | 简单弹窗权限 → 扩展为 Tool.needsPermission | R1 重构 |
| 2B | XcodeGen 替代 SPM library target | 统一管理依赖 |
| Bug1 | 给 FileTreeNode struct 加 @MainActor | SwiftUI View 调用 @MainActor 依赖 |
| R1-1 | Tool 协议用 protocol extension 默认值 | 现有 10 工具零改动 |
| R1-2 | ToolExecutionContext 新增属性全可选 | 现有工具 execute 不受影响 |
| R1-3 | ToolPermissionDecision 避免命名冲突 | PermissionEngine 已有 PermissionDecision |
| R1-4 | WebSearchResult 避免命名冲突 | FileSystemService 已有 SearchResult |
| R2-1 | Sub-agent 不需 fork | 创建新 AgentLoop actor 实例 |
| R2-2 | 子 agent 共享 ToolRegistry + 独立 PermissionEngine(.plan) | 仅只读工具 |
| R2-3 | MCP 远程用 URLSession + JSON-RPC 2.0 | 不复用 SSEStream |
| R3-1 | ContentView 横屏 NavigationSplitView + 竖屏 TabView | ⚠️ 已知 Bug: iPad 都是 regular |
| R3-2 | 删 4 Git 视图，留 3 只读 | 决策 6 |
| Q7 | MCP 本地 posix_spawn+pipe 已验证可行 | 白泽 PythonSpawnStrategy 已有先例 |
| Q8 | 向量记忆推荐远程嵌入 API | onnxruntime-ios 增 50-80MB |
| v14-1 | iPad 入口用右侧栏 + sheet | TabView 在 iPad 不执行，用户拍板方案 B |
| v14-2 | ConfigBackupService 备份到 config.json | globalConfig 路径已定义但从未实现 |
| v14-3 | NodeRuntimeEngine 加 --jitless | entitlements JIT 受限 |

---

## 13. 常见坑和注意事项

1. **gh CLI 路径**: Windows 下可能没有 `gh`，用 `curl + GitHub API` 代替
2. **SSH 子模块**: ios_system 的 wasm3 子模块用 SSH URL，需要 `git config --global url."https://github.com/".insteadOf "git@github.com:"`
3. **xcpretty 是 Ruby Gem**: 不是 Homebrew formula，用 `gem install`
4. **macOS Runner**: 必须是 `macos-15`（Xcode 16）
5. **CRLF 警告**: 不用管，Windows Git 自动换行转换
6. **IPA 签名**: 用 `ldid` 而不是 Apple 证书
7. **git 身份**: 新克隆需 `git config user.email` + `git config user.name`
8. **SwiftUI View + @MainActor**: 给整个 struct 加 @MainActor
9. **Token 不写明文**: GitHub secret scanning 会拒绝
10. **命名冲突**: 新增类型前先 grep 检查
11. **iPad size class**: 永远是 .regular，不能用 size class 判断横竖屏
12. **FileManager 权限**: TrollStore no-sandbox 环境下 FileManager.default 可能有残留限制（Bug #7）
13. **git 命令**: iOS 无 git 二进制，必须用 GitService(libgit2)，不能走 ExecuteCommand（Bug #5-6）
14. **不要盲猜**: 不确定的技术判断先核验，不要凭感觉下结论

---

## 14. 方案文档位置

所有方案文档在旧 workspace `D:\111\2026-06-21-22-21-21\`：
- `白泽重构方案_v1.md` / `白泽重构方案_v2_6决策.md` / `PRD_白泽重构_v1.md` / `ARCH_白泽重构_v1.md`

真机测试指南在当前 workspace `D:\111\2026-06-22-01-53-39\`：
- `白泽真机测试指南_v1.md`

用户测试反馈在 `D:\UUCloud_Download\文本.txt`（已读完，内容在第 2 节）

---

## 15. 下一位 AI 的首要任务

### 如果积分耗尽中断，下一位 AI 需要：

1. **读完本文档**（特别是第 2 节 25 个 Bug + 第 3 节修复进度）
2. **查看代码当前状态**：`git log --oneline -5` + `git status`，确认最后一个 commit
3. **查看本文档第 3 节**的"修复进度跟踪"表，确认哪些已修哪些待修
4. **继续按优先级修 Bug**：
   - P0 先修（5 个阻塞核心）
   - 每修完一个 → 更新本文档第 3 节"已修"部分 → commit + push → 盯 CI
   - CI 通过后继续下一个
5. **修 Bug 走 BugFix 快捷路径**：TeamCreate → 工程师(定位+修复) → QA(回归)
6. **修完所有 P0 后通知用户测试**，收集新反馈

### P0 修复指引（具体方向）

#### Bug #7 创建项目权限失败
- 文件：`Views/Dashboard/NewProjectWizard.swift:196` createEmptyProject
- 核验：`BaizePath.projectRoot = "/var/mobile/Documents/Baize/"`
- 方向：检查 entitlements 是否有 `com.apple.private.security.no-sandbox`；检查 FileManager.default 在 TrollStore 下的实际行为；可能需要用 posix_spawn 调用 mkdir

#### Bug #5-6 Git 命令沙箱不可用
- 文件：`Tools/ExecuteCommandTool.swift` + `Infrastructure/NativeCommands.swift`
- 根因：AI 调用 ExecuteCommand 执行 `git status`，但 iOS 无 git 二进制，ios_system 拦截报错
- 方向：新建 `GitTool.swift` 封装 GitService(libgit2)，注册到 ToolRegistry，让 AI 调用 GitTool 而非 ExecuteCommand 执行 git；或在 ExecuteCommand 里拦截 git 命令转给 GitService

#### Bug #15-17 PlanMode 只进不出
- 文件：`Agent/PlanMode/PlanModeState.swift` + `Tools/ExitPlanModeTool.swift` + `Views/Dialogs/PlanApprovalView.swift`
- 核验：PlanModeState 的 enter/exit/approve/reject 完整流程；ExitPlanModeTool 是否正确触发审批；PlanApprovalView 是否正确绑定到 AgentEvent.planApprovalRequested
- 方向：可能是审批 continuation 没正确 resume，或 sheet 没弹出

#### Bug #24 子 agent 被拒 + 绕过模式仍询问
- 文件：`Agent/PermissionEngine.swift` + `Agent/SubAgent/AgentTool.swift`
- 核验：PermissionEngine.evaluate 在 bypass 模式下是否跳过所有权限；isToolReadOnly 判断是否正确
- 方向：bypass 模式应直接 .allow 所有工具；AgentTool 不应被标记为写操作

#### Bug #3 工具参数显示"无"
- 文件：`Views/Chat/ToolCallView.swift` + `Views/Chat/ChatView.swift`
- 核验：ToolCallView 渲染参数的逻辑；ChatView 是否实时刷新工具调用状态
- 方向：可能是 @State 没正确绑定，或工具调用参数解析有误

---

## 16. 前任 AI 的总结

```
我（v14 这一任 AI）的工作：
- 接手 v13 交接文档
- QA 验证 T01-T04 代码 → 修 3 个编译错误
- 6 轮 CI 编译修复（#118-#123）→ 首次编译成功
- 全量代码审查 125 文件 → 修 14 个 Bug
- 实现配置备份/恢复（ConfigBackupService）解决设置丢失
- 修复 iPad 入口缺失（右侧栏 + 三个 sheet）
- 用户真机测试反馈 25 个 Bug
- 正在写本交接文档 + 准备修 P0 Bug

你（接手的 AI）只需要：
1. 读完本文档
2. 查看第 3 节修复进度，确认哪些已修
3. 继续按 P0 → P1 → P2 顺序修 Bug
4. 每修完一个 → 更新本文档 → commit + push → 盯 CI
5. P0 全修完通知用户测试

核心原则（血泪经验）：
1. 用户积分金贵，别浪费轮次
2. 不懂别装懂，不要盲猜，不确定就去核验
3. 不要偷工减料，走标准化流程
4. Swift 6 actor 隔离是地雷
5. Token 不能写进 commit
6. 用户说话直来直去，你也别废话
7. iOS 可行性必须验证
8. 以白泽为基底，不推倒重来
9. 坚持 iOS 平台
10. 对标 Claude Code/Codex
11. iPad size class 永远是 .regular
12. 每修完一个 Bug 立即更新交接文档 + commit

祝顺利 🔧
```

---

## 17. 安全提醒

⚠️ **GitHub Token 已在对话历史中明文暴露**（见 git remote URL）。

**强烈建议**：
1. 让用户去 GitHub Settings → Developer settings → Personal access tokens 撤销这个 token
2. 生成新 token
3. 更新 git remote URL：`git remote set-url origin https://<新token>@github.com/Da-AiXZ/BaiZe.git`

---

*生成时间: 2026-06-22 12:50 | 项目: 白泽 Baize iOS 本地编程智能体 | 阶段: 真机测试完成，25 Bug 待修 | 版本: v14*
