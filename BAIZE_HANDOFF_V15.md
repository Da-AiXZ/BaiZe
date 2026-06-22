# 白泽 (Baize) — AI 继承者交接文档 v15

> **给下一位 AI 的话**：v14 修了 39 个 Bug，v15 发现是**架构问题**——补丁修不好。
> 已读完 4 份参考资料（Claude Code 源码/Operit+ms-agent/6 框架对比/18 小项目）。
> **你的任务：做架构师，基于研究结论做技术选型 + 输出架构设计 + 任务分解。**

> **生成时间**: 2026-06-23 02:00 | **版本**: v15
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 接手 v14 → 两轮 39 Bug 修复 → 真机反馈发现架构问题 → 读完所有参考资料 → 写重构方向

---

## 0. TL;DR

1. **项目位置**: `D:\2\WorkBuddy\2026-06-21-18-14-27\baize`（用户已从 C 盘迁移过来）
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe（分支 `main`）
3. **最新 commit**: `ea8ff2f`（CI #136 ✅）
4. **Token**: 已嵌入 git remote URL，有效（用户生成的新 token）
5. **当前状态**: **暂停 BugFix，转向架构重构**。两轮修了 39 个 Bug 但 3 个核心 Bug 反复修不好，诊断是架构层根本问题
6. **你的角色**: 架构师高见远。先读参考资料 → 做技术选型 → 输出架构设计 + 任务分解
7. **积分警告**: 用户积分随时耗尽。每输出一个交付物就 commit+push

---

## 1. 你的任务：先做架构师

**你是架构师高见远**，不是工程师（暂不写代码）。任务分三步：

### Step 1: 读资料（1 小时）
必读文件（按顺序）：
1. `D:/111/2026-06-22-16-57-20/白泽重构PRD_v15.md` — PM 的诊断报告（5 个架构层根因 + 重构范围 + iOS 约束）
2. `D:/111/2026-06-22-16-57-20/白泽架构师输入包.md` — 4 份研究的精简摘要（权限/Git/SubAgent/PlanMode/Memory/Skills 各方案速查）
3. `D:/2/WorkBuddy/2026-06-21-18-14-27/baize/BAIZE_HANDOFF_V14.md` 第 7 节（iOS 特有约束）— 理解平台硬限制
4. 根据选型需要，深入读完整研究报告：
   - Claude Code 源码: `D:/UUCloud_Download/1/claude-code-main.tar.gz`（10MB，解压用）
   - 6 框架对比: `D:/111/2026-06-22-16-57-20/.tmp/research/frameworks-comparison-report.md`
   - 18 项目研究: `D:/111/2026-06-22-16-57-20/research-summary.md`

### Step 2: 做技术选型（回答 PM 的 6 个问题）

**Q1: Git HTTPS 传输层方案？**
- 方案 A: 打包静态编译 git 二进制 + Swift Process API（Claude Code 方案，彻底解决 TLS）
- 方案 B: SwiftGit（纯 Swift libgit2 绑定 + 自定义 TLS 后端）
- 方案 C: URLSession 重写 smart HTTP + libgit2 只做本地操作
- **参考**: Claude Code 完全 shell out；Operit 也靠 Ubuntu 内置 git。iOS 上需验证 Process 在 TrollStore 可否 spawn 外部二进制

**Q2: 子 Agent 隔离方案？**
- 方案 A: Swift actor 独立实例 + 独立的 PermissionEngine/toolRegistry/事件流（Claude Code createSubagentContext 模式）
- 方案 B: 方案 A + Swift TaskGroup 真并行
- **参考**: Claude Code setAppState no-op + localDenialTracking 独立 + UI 回调全 nil

**Q3: Skills 执行模型？**
- 方案 A: 全部 fork 模式（Claude Code 方式，在独立 subagent 执行）
- 默认 fork，砍 inline（iOS 不能 spawn shell）
- **参考**: Claude Code context: fork；crewAI 三级披露；adk toolset 动态加载

**Q4: Memory 存储？**
- 方案 A: 纯文件系统（Claude Code 方式，MEMORY.md + 主题文件）
- 方案 B: SQLite + mem0 提取逻辑 + ContextDB 双时态
- **参考**: Claude Code MEMORY.md；ms-agent ContextCompressor 两步压缩；mem0 ADDITIVE_EXTRACTION_PROMPT

**Q5: 文件系统访问统一机制？**
- 方案 A: 全量切 ios_system（posix_spawn 在 iOS 找不到 /bin/mkdir）
- 方案 B: 启动时探测可用方式，fallback 链
- **参考**: v14 第 7 节 iOS 约束；Operit 5 级 Shell 通道思路（但 iOS 只能 1 级）

**Q6: 权限引擎统一为单一决策点？**
- 方案 A: 5 模式 + 三层规则 + safetyCheck bypass 免疫（Claude Code 模型）
- 决策流水线: denyRule → askRule → safetyCheck → mode-allow → default-ask
- **白泽改进**: ToolRegistry.isEnabled(mode) 硬拦截层（PlanMode 下写工具直接 isEnabled=false）
- **参考**: Claude Code permissions.ts:1158-1310；shipit_agent PermissionEngine

### Step 3: 输出架构设计 + 任务分解
参考 v14 第 9 节（当前文件结构），输出：
1. 重构后的文件结构（新增/修改/删除）
2. 任务列表（有序、含依赖、按 Phase 排列）
3. 每个 Phase 有独立可交付的 IPA 里程碑
4. 关键接口定义（PermissionEngine / SubAgentContext / GitService / SkillExecutor / MemoryExtractor）

---

## 2. 两轮 BugFix 修复记录

### 第一轮（CI #127 → #134，27/28）
- 7 commits: a0820f4 → ea4fc30
- 修了 P0×8 + P1×14 + P2×6（B09 subagent 并行未修）
- 用户真机测试发现 11 个没修好

### 第二轮（CI #136，11/11 深度修复）
- 2 commits: 1c82a13 + ea8ff2f
- 找到真根因：B01 ios_popen 回退 / B02 libgit2 OpenSSL TLS 问题 / B05 bypass 条件被移除 / B08 独立 PermissionEngine / B14 updateUIView 同步 / 等等
- **用户反馈**: 仍有很多问题。来来回回这几个 Bug → 诊断是架构问题

### 反复修不好的 3 个 Bug（架构层根因）
1. **B01 创建目录**: FileManager/posix_spawn/ios_system 三套文件系统访问互不兼容
2. **B02 git fetch 0 字节**: libgit2+OpenSSL 在 iOS TrollStore 访问不了系统 Keychain CA
3. **B08 subagent**: 共享父 agent 状态→权限污染+中间事件写入主对话+进程工具卡死

---

## 3. 架构层诊断（5 个根因，来自 PM PRD v15）

### 根因一: 文件系统访问层未做平台验证
- FileManager.default 在 TrollStore 有残留沙盒限制
- posix_spawn 在 iOS 找不到 /bin/mkdir 二进制
- ios_popen (ios_system 内置 mkdir) 是刚加的第 4 级回退，未真机验证
- **结论**: 必须统一为 1 套可用方案，不是累加回退链

### 根因二: Git HTTPS 传输层有不可修复的平台缺陷
- libgit2 用 OpenSSL 做 HTTPS
- iOS TrollStore 下 OpenSSL 无法访问系统 Keychain CA 证书
- 当前"接受任何证书"是安全漏洞（MITM 可拦截 Git token）
- **结论**: 必须放弃 libgit2 HTTPS，改用其他方案

### 根因三: 子 Agent 共享基础设施导致并发污染
- 子 agent 共享 RuntimeExecutor（posix_spawn pipe 不线程安全）
- 子 agent 共享 PermissionEngine / planModeState
- 子 agent 事件写入主对话 messages
- **结论**: 必须完全隔离（Claude Code createSubagentContext 模式）

### 根因四: Skills 和 Memory 是占位实现
- Skills 只返回 workflow 文本让 AI 按步骤执行——没真正实现
- Memory 目录创建静默失败（`try? fm.ensureDirectoryExists` 吃掉了错误）
- Memory 从未提取过——没接 stopHooks
- **结论**: Skills 需 fork 模式真正执行；Memory 需接 stopHooks + 预创建目录

### 根因五: 权限引擎三层决策不同步
- PermissionEngine + PlanModeState + AgentLoop 各自做权限判断
- bypass 模式能绕过 PlanMode 只读约束（安全底线被破坏）
- **结论**: 必须统一为单一决策点 + PlanMode 硬拦截层

---

## 4. 研究结论速查（4 份资料已全部读完）

### 必采纳方案（P0）
1. **权限系统**: 5 模式(default/acceptEdits/plan/bypassPermissions/dontAsk) + 三层规则 + safetyCheck bypass 免疫 → Claude Code
2. **Git**: 放弃 libgit2，改 shell out 到系统 git 二进制 → Claude Code
3. **SubAgent**: createSubagentContext 完全隔离 → Claude Code
4. **PlanMode**: ExitPlanModeTool requiresUserInteraction=true + ToolRegistry.isEnabled(mode) 硬拦截 → Claude Code + 白泽改进
5. **Memory**: stopHooks 触发 + ensureMemoryDirExists 预创建 + forked subagent 提取 → Claude Code
6. **AskUserQuestion**: 答案写 updatedInput.answers → tool_result → Claude Code

### 强烈推荐（P1）
7. **ContextCompressor**: 两步压缩（prune 工具输出 40k 保护 + LLM 摘要）→ ms-agent
8. **工具并行白名单**: 只读并行，写串行 → Operit
9. **Skills 全 fork**: 砍 inline，SKILL.md + frontmatter + paths 条件激活 → Claude Code + crewAI 三级披露
10. **Swift 移植参考**: adk-dart 语言最近（Dart→Swift 直接映射）→ 6 框架对比结论

### iOS 关键约束速查
- 禁止 fork() → 用 posix_spawn
- 禁止 JIT → Node --jitless
- TrollStore 无沙盒但 FileManager.default 有残留限制
- 无 git 二进制（需打包静态编译版本）
- 无 /bin/mkdir（需 ios_system 内置 mkdir 或 Process 调用打包的 mkdir）
- OpenSSL 访问不了 Keychain CA 证书（证书验证问题）
- CPython 3.13 + nodejs-mobile + ios_system + libgit2 + Monaco(WKWebView)

---

## 5. 项目文件结构（当前，来自 v14 第 9 节）

```
baize/
├── BAIZE_HANDOFF_V14.md
├── BAIZE_HANDOFF_V15.md  ← 本文档
├── project.yml
├── .github/workflows/build.yml
└── Baize/Baize/
    ├── App/             BaizeApp.swift, AppState.swift
    ├── Agent/           AgentLoop.swift, PermissionEngine.swift, Tool.swift,
    │   ├── PlanMode/    PlanModeState.swift
    │   ├── SubAgent/    AgentTool.swift ← ⚠️ 架构问题
    │   ├── Skills/      SkillRegistry, SkillTool ← ⚠️ 占位
    │   ├── Memory/      MemoryStore, MemoryExtractor ← ⚠️ 占位
    │   ├── Commands/    CommandRegistry
    │   └── ...
    ├── Services/        GitService.swift ← ⚠️ libgit2 架构问题
    ├── Tools/           ExecuteCommandTool.swift, 等 24 个工具
    ├── Views/
    │   ├── Chat/        ChatView, ChatInputView, MessageBubble, ToolCallView
    │   ├── Dashboard/   NewProjectWizard.swift ← ⚠️ 目录创建
    │   ├── Editor/      EditorContainerView
    │   └── ...
    ├── Utils/           Extensions.swift ← ⚠️ ensureDirectoryExists 4 级回退
    ├── Models/          GitModels.swift
    └── Infrastructure/  RuntimeExecutor.swift, 等
```

---

## 6. 参考资料位置

| 资料 | 路径 | 大小 | 重要性 |
|------|------|------|--------|
| Claude Code 官方源码 | `D:/UUCloud_Download/1/claude-code-main.tar.gz` | 10MB | ⭐⭐⭐⭐⭐ |
| cc-haha (Electron 重写) | `D:/netease/Downloads/cc-haha-main.zip` | 116MB | ⭐⭐ |
| Operit (Android AI 助手) | `D:/netease/Downloads/Operit-main.zip` | 78MB | ⭐⭐⭐ |
| 6 框架对比报告 | `D:/111/2026-06-22-16-57-20/.tmp/research/frameworks-comparison-report.md` | - | ⭐⭐⭐⭐ |
| 18 项目研究报告 | `D:/111/2026-06-22-16-57-20/research-summary.md` | 40KB | ⭐⭐⭐⭐ |
| 架构师输入包 | `D:/111/2026-06-22-16-57-20/白泽架构师输入包.md` | - | ⭐⭐⭐⭐⭐ |
| PM 重构 PRD v15 | `D:/111/2026-06-22-16-57-20/白泽重构PRD_v15.md` | - | ⭐⭐⭐⭐⭐ |
| 其余 14 个 zip | `D:/UUCloud_Download/1/` | 总计 700MB | ⭐（已研究完，结论在报告中） |

---

## 7. 用户偏好（来自 v14 第 10 节 + 新增）

- 直来直去，别废话
- 不懂别装懂，不会的就去搜/核验
- 不要偷工减料，走标准化流程
- 不要盲猜，不确定的就去核验、查清
- 积分有限，高效不浪费轮次
- **新增**: 不信任补丁式修复，要求到根因。如果反复修不好，说明架构问题，需要重构

---

## 8. 关键教训（血的教训，读三遍）

1. **不要用 FileManager.default 在 TrollStore 创建目录**——有残留沙盒限制
2. **不要用 libgit2+OpenSSL 做 HTTPS 在 iOS**——访问不了 Keychain；用 shell out git 二进制
3. **子 agent 不要共享父 agent 的 PermissionEngine/planModeState/事件流**——必须完全隔离
4. **PlanMode 写操作拦截不能被 bypass 跳过**——必须是独立安全约束
5. **Memory 提取必须接 stopHooks**——不是等用户手动触发
6. **Skills 必须用 fork 模式真正执行**——不是返回文本让 AI "自觉"
7. **修复 Bug 前先读代码确认根因**——第一轮盲改导致 11 个回归就是教训
8. **iOS 上不要假设有 /bin/mkdir**——用 ios_system 内置 mkdir

---

## 9. 架构师开工指引

1. **先读** `白泽架构师输入包.md` + `白泽重构PRD_v15.md`（在 `D:/111/2026-06-22-16-57-20/`）
2. **需要看源码时**解压 `D:/UUCloud_Download/1/claude-code-main.tar.gz`，重点看:
   - `src/utils/permissions/permissions.ts`（权限系统决策流水线）
   - `src/utils/forkedAgent.ts`（createSubagentContext 隔离）
   - `src/tools/AgentTool/runAgent.ts`（subagent 启动逻辑）
   - `src/skills/loadSkillsDir.ts`（Skills 加载）
   - `src/services/extractMemories/extractMemories.ts`（Memory 提取）
   - `src/tools/ExitPlanModeTool/ExitPlanModeV2Tool.ts`（PlanMode 审批）
   - `src/tools/AskUserQuestionTool/AskUserQuestionTool.tsx`（AskUser 回传）
3. **做技术选型**（回答第 1 节的 Q1-Q6）
4. **输出架构设计**（文件结构 + 任务列表 + Phase 里程碑）
5. **commit + push** 你的设计文档，然后工程师实现

---

## 10. GitHub Token 管理

- Token 已嵌入 git remote URL（`https://<token>@github.com/Da-AiXZ/BaiZe.git`）
- 用户用完可去 https://github.com/settings/tokens 撤销
- commit + push 命令: `cd D:/2/WorkBuddy/2026-06-21-18-14-27/baize && git add -A && git commit -m "..." && git push origin main`

---

*生成时间: 2026-06-23 02:00 | 版本: v15 | 前任 AI: 齐活林*
*本次会话: 接手 v14 → 两轮 39 Bug → 发现架构问题 → 读完 4 份参考资料 → 写重构方向*
*下一位角色: 架构师高见远*
