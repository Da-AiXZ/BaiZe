# 白泽 (Baize) — AI 继承者交接文档 v12

> **给下一位 AI 的话**：这份文档就是你的"记忆"。读完 ≈ 你跟着我从头干到了这里。
> 严格按文档指示操作，不要自己瞎猜。
> 
> **生成时间**: 2026-06-21 20:47 | **版本**: v12（替代已销毁的 v11）
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP

---

## 0. TL;DR — 最重要的事先说

1. **项目位置**: `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe (分支 `main`)
3. **GitHub Token**: 见下方"Token 获取方式"（不能写明文，GitHub secret scanning 会拒绝 push）
   - 使用方式: `git clone https://x-access-token:TOKEN@github.com/Da-AiXZ/BaiZe.git`
   - **Token 获取方式**:
     - 方式 1: 问用户要（用户知道 token）
     - 方式 2: 查看本地工作区记忆文件 `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\.workbuddy\memory\MEMORY.md`
     - 方式 3: 查看 git remote URL — `git -C "C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize" remote -v` 输出里包含 token
     - ⚠️ **这个 token 已暴露在对话历史中，建议用户撤销重新生成**
4. **最新提交**: `42b9771` (2026-06-21)
5. **最新 IPA**: 56.2MB, Run #117, 下载页 https://github.com/Da-AiXZ/BaiZe/actions/runs/27903900194
6. **当前状态**: 6 个真机 Bug 已修复 + CI 通过 + IPA 已生成，**等待用户装新版验证**
7. **未完成**: 真机第 3-8 层测试（代码执行/Git/多模型/项目切换）尚未验证

---

## 1. 我是谁，我在干什么

### 项目身份
- **名称**: 白泽 (Baize) — iOS 本地编程智能体
- **类比**: 像 Claude Code / Codex，但跑在 iPad Pro M1 本地
- **运行环境**: iPad Pro 2021 M1, iOS 16.6.1, 通过 TrollStore 免签安装
- **构建方式**: GitHub Actions CI (macos-15 runner) → 编译 IPA → ldid fakesign → 下载安装
- **技术栈**: Swift + SwiftUI | libgit2 C API | nodejs-mobile (--jitless) | CPython 3.13 | ios_system | Monaco Editor (WKWebView)

### 仓库与路径
| 字段 | 值 |
|------|------|
| GitHub 仓库 | https://github.com/Da-AiXZ/BaiZe |
| 分支 | main |
| 本地路径 | `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\baize` |
| GitHub Token | `<GH_TOKEN见memory或问用户>` |
| 最新提交 | `42b9771` (2026-06-21) |
| CI 最新通过 | Run #117 (success) |
| IPA 大小 | 56.2MB |

### 当前阶段
**真机验证阶段** — 所有规划功能已编码完成，CI 通过，IPA 已生成。用户已安装第一批修复版（commit 42b9771），正在逐层验证。第 1-2 层（启动+文件）已测完并修复 6 个 Bug，第 3-8 层（代码执行/Git/多模型等）尚未测试。

---

## 2. 版本进度全景

### 已完成的阶段
```
Phase 1   ✅  PRD + 架构 + 代码 + QA
Phase 2A  ✅  23 个 Warning 修复
Phase 2B  ✅  构建系统重构 (XcodeGen + CI/CD + IPA)
Phase 2C  ✅  多模型支持 (OpenAI/Anthropic/OpenRouter/Custom OpenAI)
Phase 2D  ✅  Monaco Editor 真实集成 (WKWebView + 诊断面板)
功能补全  ✅  T01-T05 全部完成 (16 项功能)
Bug 修复  ✅  7 个 P0/P1 Bug (会话隔离/长内容/上下文/滚动/焦点/流式)
终端 UI   ✅  TerminalPane + 历史持久化 + 原生命令 (ls/cat/grep/find)
真机测试  🔄  第 1-2 层完成 (6 Bug 已修)，第 3-8 层待测
```

### 提交统计
- 124 条提交（截至 42b9771）
- 88 个 Swift 源文件
- CI #117 通过 ✅

---

## 3. 真机测试第一批 Bug 修复详情 (2026-06-21)

用户在 iPad 真机测试发现 6 个 Bug，已全部修复并 CI 通过。

### Bug 列表与修复

| # | Bug | 优先级 | 修复方案 | 涉及文件 |
|---|-----|--------|---------|---------|
| 1 | 文件树深层目录点击不展开 | P0 | 递归 DisclosureGroup 替代 OutlineGroup + struct 加 @MainActor | FileExplorerView.swift |
| 2 | Monaco Tab 关闭/切换困难 | P1 | 关闭按钮常显+增大触摸区+contentShape 分离 | EditorTabBar.swift |
| 3 | 重启后终端历史清空 | P1 | UserDefaults 持久化上次项目路径 | Constants/AppState/BaizeApp.swift |
| 4 | Git push 假成功 | P0 | push 前检查 staged 未 commit + OID 比较 | GitService/GitViewModel.swift |
| 5 | 新建项目权限错误 | P0 | Info.plist 加 UIFileSharingEnabled + 启动建目录 | Info.plist/BaizeApp/AppState/NewProjectWizard.swift |
| 6 | 折叠不全+导出黑屏 | P1 | 折叠改 800 字段落截断 + ShareSheet 验证文件 | MessageBubble/ShareSheet/SessionListView.swift |

### CI 构建过程（重要经验）
6 Bug 修复提交后 CI 连续失败 3 次，根因都是 Bug 1 修复引入的 Swift 6 actor 隔离问题：

| CI | 结果 | 原因 |
|----|------|------|
| #114 | ❌ | FileTreeNode 方法调用 @MainActor 的 appState |
| #115 | ❌ | 给方法加 @MainActor → 闭包调用处报错 |
| #116 | ❌ | 用 Task { @MainActor in } 包裹 → 方法内部调用仍报错 |
| **#117** | ✅ | **给整个 FileTreeNode struct 加 @MainActor** |

**⚠️ 关键教训**: SwiftUI View struct 中如果有方法调用 @MainActor 的依赖（如 AppState），最干净的方案是给整个 struct 加 @MainActor，而不是给单个方法加或用 Task 包裹。

### 相关提交
- `ff7f1f2` — 6 Bug 修复主体
- `bcbbd9b` — FileTreeNode 方法加 @MainActor（CI #115 仍失败）
- `b210149` — FileTreeNode 用 Task @MainActor 包裹（CI #116 仍失败）
- `42b9771` — 给整个 FileTreeNode struct 加 @MainActor（CI #117 ✅ 通过）

### QA 遗留 WARN
`NewProjectWizard.swift:155` 使用 `BaizePath.projectRoot`（硬编码 TrollStore 路径）而非 `appState.currentProjectPath`。在 TrollStore 生产环境不影响，但严格来说应使用 `appState.currentProjectPath` 以支持沙箱 fallback。建议后续优化。

---

## 4. 待完成的真机测试（第 3-8 层）

用户已测完第 1-2 层（启动+聊天+文件操作），第 3-8 层尚未测试。**这是接手 AI 的首要任务**：等用户装上 commit 42b9771 的新 IPA 后，引导用户继续测试。

### 第 3 层｜代码执行（🔴 高风险，未测）
1. 终端输入 `ls` / `pwd` / `echo hello`
2. 让 AI "创建 hello.py 并运行"
3. 让 AI "写一个 JS 脚本打印 1+1 并运行"
4. 重启 App 后终端历史是否还在（Bug 3 修复验证）
5. **风险点**: posix_spawn + nodejs-mobile --jitless 在 TrollStore no-sandbox 下从未验证过

### 第 4 层｜Git 操作（🔴 高风险，未测）
1. Git Tab 显示当前仓库状态
2. 暂存文件 → **提交**（输入提交消息）→ 推送
3. **重点验证 Bug 4 修复**: 确认推送后远程仓库真的有更新
4. Git pull/fetch 拉取远程更新
5. Git branch 创建/切换/删除
6. Git stash 暂存/恢复
7. **风险点**: libgit2 C API 在 iOS arm64 上的内存管理/冲突处理从未验证

### 第 5 层｜多项目管理（🟡 中风险，未测）
1. Dashboard → 新建项目 → 空项目（验证 Bug 5 修复：不再报权限错）
2. 切换到新项目，验证文件树/终端/会话联动
3. Dashboard 用量统计是否更新

### 第 6 层｜聊天增强（🟡 中风险，未测）
1. 让 AI 写一篇 4000+ 字的内容，验证折叠/展开（Bug 6 修复验证）
2. 会话搜索功能
3. 导出对话（验证 Bug 6 修复：弹窗不黑屏）

### 第 7 层｜多模型（🟡 中风险，未测）
1. 切换到 Anthropic (Claude) — 需用户有 Anthropic API Key
2. 切换到 OpenRouter — 需用户有 OpenRouter API Key
3. **注意**: 用户说"只有一个 API Key"，此层可能无法完整测试

### 第 8 层｜Monaco 编辑器（🟡 中风险，未测）
1. 点击文件在编辑器中打开
2. 语法高亮是否正常
3. 编辑内容 + 保存
4. 多 Tab 切换（Bug 2 修复验证）

---

## 5. CI/CD 管道速查

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

# 下载失败日志（获取 job_id 后）
JOB_ID=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/<RUN_ID>/jobs" \
  | python -c "import json,sys; print(json.load(sys.stdin)['jobs'][0]['id'])")
curl -sL -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/jobs/${JOB_ID}/logs" \
  -o /tmp/ci-logs.txt

# 搜索编译错误
grep -E "❌|error:" /tmp/ci-logs.txt | grep -v "didFail\|withError\|Build Status" | head -20
```

### 前台盯 CI 构建（用户要求不用后台）
```bash
# 等 CI 触发后，前台轮询每 45-60 秒检查一次
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

## 6. 项目文件结构

```
baize/
├── .github/workflows/build.yml    ← CI/CD 流水线
├── project.yml                    ← XcodeGen 项目规范
├── scripts/
│   ├── build-ipa.sh               ← 从 xcarchive 打包 IPA + ldid 签名
│   ├── verify-ipa.sh              ← IPA 完整性验证
│   ├── download-runtime.sh        ← 下载 node/python 运行时
│   ├── download-monaco.sh         ← 下载 Monaco Editor npm 包
│   └── patch-xcframeworks.sh      ← 修补 xcframework
├── Baize/
│   ├── Baize.xcodeproj/           ← XcodeGen 生成，不提交
│   └── Baize/
│       ├── App/
│       │   └── BaizeApp.swift     ← @main 入口 + DI 容器
│       ├── Agent/                 ← Agent 循环 + 工具 + 权限
│       │   ├── AgentLoop.swift    ← actor 主循环
│       │   ├── ToolRegistry.swift ← actor 工具注册表
│       │   ├── PermissionEngine.swift
│       │   ├── ProjectContext.swift
│       │   ├── ContextManager.swift
│       │   ├── ConversationStore.swift
│       │   ├── Message.swift
│       │   └── ...
│       ├── Infrastructure/
│       │   ├── APIGateway.swift       ← LLM API 网关 (actor)
│       │   ├── SSEStream.swift        ← SSE 流解析器
│       │   ├── FileSystemService.swift
│       │   ├── KeychainService.swift
│       │   ├── RuntimeExecutor.swift  ← posix_spawn 执行引擎
│       │   ├── MonacoBridge.swift     ← WKWebView ↔ Monaco 桥接
│       │   ├── NativeCommands.swift   ← 原生命令 (ls/cat/grep/find)
│       │   ├── NodeRuntimeEngine.swift
│       │   ├── PythonRuntimeEngine.swift
│       │   ├── RuntimeStrategy.swift
│       │   └── Providers/
│       │       ├── LLMProvider.swift      ← 协议
│       │       ├── OpenAIProvider.swift
│       │       ├── AnthropicProvider.swift
│       │       ├── OpenRouterProvider.swift
│       │       ├── CustomOpenAIProvider.swift
│       │       └── OpenAICompatibleHelper.swift
│       ├── Tools/                 ← 10 个内置工具
│       │   ├── ReadFileTool / WriteFileTool / EditFileTool
│       │   ├── DeleteFileTool
│       │   ├── ListDirectoryTool / SearchFilesTool / SearchContentTool
│       │   ├── ExecuteCommandTool / RunNodeTool / RunPythonTool
│       ├── Services/
│       │   ├── GitService.swift       ← libgit2 封装 (12+ Git 操作)
│       │   ├── ProjectRegistry.swift  ← 项目注册表 (actor)
│       │   ├── UsageTracker.swift     ← API 用量统计
│       │   ├── TerminalHistoryStore.swift ← 终端历史持久化
│       │   ├── ConversationExporter.swift
│       │   └── ProjectTemplate.swift
│       ├── ViewModels/
│       │   └── GitViewModel.swift
│       ├── Views/
│       │   ├── ContentView.swift      ← 三栏布局
│       │   ├── Chat/                  ← 聊天视图 (7 文件)
│       │   ├── Editor/                ← 编辑器 (2 文件)
│       │   ├── Git/                   ← Git UI (7 文件)
│       │   ├── Terminal/              ← 终端 UI (3 文件)
│       │   ├── Dashboard/             ← Dashboard (2 文件)
│       │   ├── Settings/              ← 设置 (5 文件)
│       │   ├── Sidebar/               ← 侧栏 (2 文件)
│       │   └── Dialogs/               ← 弹窗 (1 文件)
│       ├── Models/                    ← AppState, EditorState, GitModels
│       └── Utils/                     ← Constants, Logger, Extensions, BaizePricing
├── BaizeTests/                       ← 测试 (3 文件)
├── docs/                             ← 文档归档
├── analysis/                         ← 8 份源码分析报告
├── PRD_Baize_Feature_Completion.md   ← 功能补全 PRD (最新)
├── TDD_Baize_Feature_Completion.md   ← 功能补全 TDD (最新)
├── BAIZE_HANDOFF.md                  ← 旧交接文档 (v11, 已过时)
├── HANDOVER.md                       ← 旧交接文档 (v1, 已过时)
└── BAIZE_HANDOFF_V12.md              ← 本文档 (v12, 当前)
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
  → tool_call → ToolRegistry → 执行 → 结果
  → 循环直到 LLM 返回 finish
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

### 10 个内置工具
| 工具 | 用途 |
|------|------|
| ReadFile | 读取文件 |
| WriteFile | 写入文件 |
| EditFile | 精确编辑文件 |
| DeleteFile | 删除文件 |
| ListDirectory | 列出目录 |
| SearchFiles | 按名称搜索 |
| SearchContent | 按内容搜索 |
| ExecuteCommand | 执行 Shell 命令 (ios_system) |
| RunNode | 运行 Node.js (--jitless) |
| RunPython | 运行 Python |

### 12 个 Git 操作 (libgit2 C API)
fetch / pull / merge / rebase / stash / reset / tag / clone / deleteBranch / renameBranch / listRemoteBranches / checkoutRemoteBranch

### 4 个 LLM Provider
OpenAI / Anthropic / OpenRouter / Custom OpenAI 兼容

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

---

## 9. 关键技术决策日志

| 编号 | 决策 | 理由 |
|------|------|------|
| Q1 | 嵌入主进程（不用 App Extension） | iOS 不支持 child_process，白泽用 posix_spawn |
| Q2 | Monaco Editor via WKWebView | 参考 CodeApp 架构，用 GCDWebServer 启动本地服务 |
| Q3 | Python 最小集 + 按需 pip | Phase 1 只带最小 Python，纯 pip 包可运行时装 |
| Q4 | `/var/mobile/Documents/Baize/` 默认路径 | iOS 标准文档目录，TrollStore no-sandbox 可访问 |
| Q5 | 多 Provider 支持 | Phase 2C 加 Anthropic + OpenRouter + Custom |
| Q6 | 简单弹窗权限 | Phase 2 可升级为 ABAC 细粒度权限 |
| 2B | XcodeGen 替代 SPM library target | 统一管理依赖，CI 友好 |
| Bug1 | 给 FileTreeNode struct 加 @MainActor | SwiftUI View 调用 @MainActor 依赖最干净的方案 |

---

## 10. 常见坑和注意事项

1. **`gh` CLI 路径**: Windows 下可能没有 `gh`，用 `curl + GitHub API` 代替
2. **SSH 子模块**: ios_system 的 wasm3 子模块用 SSH URL，需要 `git config --global url."https://github.com/".insteadOf "git@github.com:"`
3. **xcpretty 是 Ruby Gem**: 不是 Homebrew formula，用 `gem install`
4. **macOS Runner**: 必须是 `macos-15`（Xcode 16），`macos-14` 的 Xcode 15 不认 project format 77
5. **CRLF 警告**: 不用管，是 Windows Git 的自动换行转换
6. **Information.plist 的 UILaunchScreen**: iOS 14+ 用字典替代 storyboard
7. **IPA 签名**: 用 `ldid` 而不是 Apple 证书 — 对 `.app/AppName` 可执行文件签名，不是整个 `.ipa`
8. **git 身份**: 新克隆的仓库需 `git config user.email` + `git config user.name` 才能 commit
9. **SwiftUI View + @MainActor**: View struct 中有方法调用 @MainActor 依赖时，给整个 struct 加 @MainActor

---

## 11. 用户偏好（重要！和这个用户协作时注意）

- **直来直去，别废话** — 不需要客套，直接说发现和建议
- **不懂别装懂，不会的就去搜** — 别捏造技术事实，不确定的去 Web 搜索验证；有需求疑问的就问用户，别自己瞎猜
- **不要偷工减料** — 每个阶段走标准化流程，QA 检测到 Critical 比做 demo 更重要
- **大布局 + 丰富元素** — 用户是视觉导向的，方案要有层次感
- **前台盯 CI** — 用户明确要求"用前台盯着，不要用后台监控"，编译失败就修改，成功再通知
- **积分有限** — 用户会提到"没积分了"，意味着要高效，不要浪费轮次，能一次搞定别分两次

---

## 12. 团队协作模式（软件公司 SOP）

本项目使用多智能体团队协作，主理人齐活林（交付总监）协调：

| 成员 | 姓名 | 职责 |
|------|------|------|
| 产品经理 | 许清楚 (Xu) | 创建 PRD 或市场/竞品研究 |
| 架构师 | 高见远 (Gao) | 系统架构 + 任务分解 |
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

## 13. 快速参考命令

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

## 14. 后续计划（接手 AI 的任务清单）

### 立即任务（等用户装新版 IPA 后）
1. 引导用户继续第 3-8 层真机测试
2. 收集新 Bug 报告
3. 走 BugFix 快捷路径修复 → CI → 新 IPA

### 短期优化（QA WARN 遗留）
1. `NewProjectWizard.swift:155` 改用 `appState.currentProjectPath` 替代 `BaizePath.projectRoot`

### 中期功能（Phase 3，待用户决定）
- Memory/Skill/Planning 系统（参考 analysis/memory-skill-planning-analysis.md）
- ABAC 细粒度权限引擎
- Git rebase --interactive（libgit2 无原生支持，需自定义 UI）
- Git cherry-pick / submodule

### 文档维护
- 旧交接文档 `BAIZE_HANDOFF.md` 和 `HANDOVER.md` 已过时，可删除或标注 deprecated
- 本文档 `BAIZE_HANDOFF_V12.md` 是当前权威交接文档

---

## 15. 前任 AI 的总结

```
我（这一任 AI）的工作：
- 从用户提供的两份旧交接文档 + GitHub 仓库重建了项目上下文
- 发现旧交接文档严重过时（停在 Phase 2B，实际已到功能补全完成）
- 拉团队修复了 iPad 真机测试第一批 6 个 Bug
- 经历 3 轮 CI 失败，最终定位 Swift 6 actor 隔离问题并修复
- CI #117 通过，IPA 56.2MB 已生成

你（接手的 AI）只需要：
1. 读完这份文档
2. 等用户装上 commit 42b9771 的新 IPA
3. 引导用户继续第 3-8 层真机测试
4. 收集新 Bug → 走 BugFix 快捷路径修复
5. 保持 CI 绿色

核心原则（前任血泪经验，务必遵守）：

1. **用户积分金贵** — 别浪费轮次，能一次搞定别分两次。前台盯 CI 别用后台，编译失败直接改，改完直接 push，别问"要不要继续"。

2. **第 3-4 层测试是生死关** — 代码执行（posix_spawn + nodejs-mobile）和 Git（libgit2 C API）从来没在真机跑过。这俩挂的概率最高，挂了就是 P0，立刻拉团队走 BugFix 快捷路径。

3. **Swift 6 actor 隔离是地雷** — 任何 SwiftUI View 调用 @MainActor 依赖（AppState/GitViewModel 等），直接给整个 struct 加 @MainActor，别试单个方法加或 Task 包裹，试了三轮才发现这个规律。

4. **Token 不能写进 commit** — GitHub secret scanning 会拒绝含明文 token 的 push。Token 存在本地记忆文件 `C:\Users\netease\WorkBuddy\2026-06-21-18-14-27\.workbuddy\memory\MEMORY.md` 和 git remote URL 里，自己去读，别复制到代码或文档里。

5. **用户说话直来直去，你也别废话** — 发现什么问题直接说，别铺垫。方案要给全，别挤牙膏。不懂别装懂，不会的就去搜，有需求疑问的就问用户，别自己瞎猜。

祝顺利 🔧
```

---

## 16. 安全提醒（CRITICAL）

⚠️ **GitHub Token `<GH_TOKEN见memory或问用户>` 已在对话历史中明文暴露**。

**强烈建议**：
1. 让用户去 GitHub Settings → Developer settings → Personal access tokens 撤销这个 token
2. 生成新 token
3. 通过环境变量或更安全的方式传递，不要再明文贴出

---

*生成时间: 2026-06-21 20:47 | 项目: 白泽 Baize iOS 本地编程智能体 | 阶段: 真机验证 | 版本: v12*
