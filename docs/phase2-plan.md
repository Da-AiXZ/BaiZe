# 白泽 Phase 2 规划方案

> 基于 Phase 1 交付物 + 技术调研 + 项目现状制定
> 制定日期：2026-06-17

---

## 一、Q1-Q6 待确认问题：调研结论

### Q1：Node.js 运行时架构 — 嵌入主进程 vs App Extension 隔离

**结论：嵌入主进程（TrollStore 免沙箱无需隔离）**

调研依据：
- nodejs-mobile 官方 Issue #25 明确声明：**child_process 在 iOS 上不支持**，`spawn/exec/fork` 均会报 `Error: spawn EPERM`，这是 iOS 内核级限制，TrollStore no-sandbox 也无法绕过 `fork()` 禁令
- CodeApp 使用 App Extension 隔离的主要原因是**App Store 审核**，而非技术必要性。App Extension 在独立进程中运行 Node.js，崩溃不影响主 App
- TrollStore 环境下无需通过 App Store 审核，App Extension 隔离的收益（崩溃隔离）远低于其代价（2 周额外工作量 + IPC 通信复杂度）
- **白泽的 RunNodeTool 已经采用"写临时文件 → posix_spawn node → 收集输出"模式**，不依赖 child_process，与 nodejs-mobile 的限制完全兼容

**影响**：无需改动 Phase 1 架构。当前方案已是最佳选择。

### Q2：Monaco Editor 版本 — CodeApp fork vs 官方 Monaco

**结论：采用 CodeApp 的 GCDWebServer 方案，但使用官方 Monaco npm 包**

调研依据：
- CodeApp 的 Monaco 实现架构：**GCDWebServer 在本地端口 20234 提供 Monaco 资源 → WKWebView 加载 → JS 双向通信**
- CodeApp 已升级为 **Monaco + Runestone 双引擎架构**：Monaco 用于需要 LSP/代码补全的场景，Runestone（纯 Swift + TreeSitter）用于轻量编辑
- 官方 Monaco npm 包持续更新（当前 v0.52+），CodeApp fork 停留在较旧版本
- 白泽 Phase 1 已实现 MonacoBridge（WKWebView + JS 通信），只需替换 placeholder HTML 为真实 Monaco 资源

**建议**：
1. Phase 2 先用 GCDWebServer 加载官方 Monaco npm 包（通过 `npm pack` 下载后嵌入 Bundle）
2. 后续可考虑加入 Runestone 作为轻量级备选引擎（P2 优先级）

### Q3：Python 包预装范围 — 最小集 vs 完整科学计算集

**结论：最小集 + 按需安装，但 pip install 在 iOS 上有限制**

调研依据：
- Python 3.13+ 官方支持 iOS 嵌入（`Python.xcframework`），这是重大利好
- **关键限制**：iOS App Store 要求所有二进制模块必须是动态库（.framework 格式），不能是 .so 文件。这意味着：
  - 纯 Python 包（如 requests, flask, jinja2）：**可以直接 pip install**，无需特殊处理
  - 含 C 扩展的包（如 numpy, pandas, cryptography）：需要编译为 iOS arm64 的 .framework，**不能运行时 pip install**
- TrollStore 免沙箱环境理论上可以绕过 App Store 的二进制格式限制，但 iOS 的动态链接器仍要求正确签名的框架
- BeeWare 的 Python-Apple-support 已提供 Python 3.14-b2 预编译二进制

**建议**：
1. Phase 2 嵌入 Python 3.13+ XCFramework（从 BeeWare 或 CPython 官方获取）
2. 预装纯 Python 最小集：pip, setuptools, wheel
3. RunPythonTool 支持运行时 `pip install`，但仅限纯 Python 包（可检测是否有 .so 文件）
4. 科学计算包（numpy 等）作为可选的 App 资源包，Phase 3 提供

### Q4：项目目录默认路径

**结论：`/var/mobile/Documents/Baize/`（建议默认），支持用户自定义**

调研依据：
- TrollStore no-sandbox 应用可访问 `/var/mobile/` 下任意路径
- `/var/mobile/Documents/` 是 iOS 标准的用户文档目录，通过 `FileManager.default.urls(for: .documentDirectory, .userDomainMask)` 获取
- Phase 1 代码中 `Constants.BaizePath.projectRoot` 已定义为 `/var/mobile/Documents/Baize/`

**影响**：Phase 1 已正确实现，无需改动。

### Q5：Phase 1 仅支持 OpenAI 是否足够

**结论：Phase 1 仅 OpenAI 已足够，Phase 2 加入多模型支持**

调研依据：
- OpenRouter 提供 300+ 模型的统一 API 接口，兼容 OpenAI 格式
- Phase 1 的 APIGateway 已实现 OpenAI SSE 流式 + Function Calling，是最佳 MVP 起点
- Anthropic API 的消息格式与 OpenAI 不同（Content Block vs tool_call），需要额外的适配层
- 国内用户访问 OpenRouter 延迟较高（3-5秒首 token），直接调用各 Provider 更优

**Phase 2 多模型方案**：
1. APIGateway 抽象为 `LLMProvider` 协议
2. 实现 `OpenAIProvider`、`AnthropicProvider`、`OpenRouterProvider`
3. ModelSettingsView 支持按任务类型选择模型

### Q6：权限模式粒度 — 简单弹窗 vs ABAC

**结论：Phase 1 已实现简化三态（allow/ask/deny），Phase 2 升级为 ABAC**

调研依据：
- Phase 1 已实现 PermissionEngine 三态策略 + 四种模式（default/acceptEdits/plan/bypass），覆盖了核心场景
- 完整 ABAC（5 Scope + 7 层优先级 + tokenized argv 匹配）参考 @ai-abacus/core 分析
- Phase 2 ABAC 增强点：
  - BAIZE.md 中的策略声明（deny_paths, allowed_commands）
  - 工具级别的细粒度策略（如 execute_command 按 command pattern 匹配）
  - 会话级别的策略缓存（"skip for session" 功能已实现但 disabled）

---

## 二、T1-T5 实测项：风险评估与应对

| # | 实测项 | 风险等级 | 调研结论 | 应对方案 |
|---|--------|---------|---------|---------|
| T1 | nodejs-mobile child_process | 🟢 已解决 | **iOS 内核级禁止 fork()，TrollStore 无法绕过**。白泽已采用 posix_spawn 模式，不依赖 child_process | 无需实测，当前方案正确 |
| T2 | ios_system no-sandbox 文件访问 | 🟡 低风险 | no-sandbox 应可访问 /var/mobile 全路径，但无公开验证案例 | 首次 IPA 安装后优先测试 |
| T3 | posix_spawn Bundle 外二进制 | 🟡 中风险 | iOS 可能仍要求签名验证。TrollStore 的 ldid fakesign 可能不够 | Phase 2 不依赖此功能，所有二进嵌入 Bundle |
| T4 | nodejs-mobile 主进程稳定性 | 🟡 中风险 | 无 App Extension 隔离，Node.js 内存泄漏会影响主 App | 加入内存监控 + 50 次循环上限 + 强制回收 |
| T5 | Monaco + Agent Loop 并发性能 | 🟢 低风险 | CodeApp 已在 App Store 验证 Monaco + Node.js + Python 同时运行 | M1 8GB 内存充裕，首测关注即可 |

**最高优先实测**：T2 > T4 > T5 > T3（T1 无需实测）

---

## 三、23 个 Warning 优先级排序

### 🔴 P0 — 必须修复（影响运行时稳定性/正确性）

| 优先级 | 编号 | 问题 | 修复文件 | 原因 |
|--------|------|------|---------|------|
| 1 | **W22+W5** | BaizeApp DI 死代码 + ChatView 重建服务 | BaizeApp.swift, ChatView.swift | **最严重**：每次消息都重建 AgentLoop/APIGateway 等服务，状态全部丢失，DI 完全失效 |
| 2 | **W8** | RuntimeExecutor 无超时 | RuntimeExecutor.swift | Agent Loop 可能无限等待，用户无法取消 |
| 3 | **W19** | AgentLoop continuation 双重 finish | AgentLoop.swift | 可能导致崩溃或内存泄漏 |
| 4 | **W6** | SSE 多行 data 未按规范连接 | SSEStream.swift | 影响 Anthropic/OpenRouter 等使用多行 SSE 的 Provider |

### 🟡 P1 — 应该修复（影响代码质量/可维护性）

| 优先级 | 编号 | 问题 | 修复文件 | 原因 |
|--------|------|------|---------|------|
| 5 | **W16** | spawnProcess stdout/stderr 死锁 | RuntimeExecutor.swift | 大输出场景可能卡死 |
| 6 | **W10** | editFile 全局替换 | FileSystemService.swift | 多处匹配时替换全部，不符合预期（应报错或仅替换第一处） |
| 7 | **W4+W23** | PermissionEngine 值语义 + ToolExecutionContext 复制 | PermissionEngine.swift, Tool.swift | 权限修改不传播，每次工具执行权限状态独立 |
| 8 | **W1** | ConversationStore 不是 Actor | ConversationStore.swift | 并发写入可能损坏 JSON 文件 |
| 9 | **W9** | isRunning 时序问题 | AgentLoop.swift | 完成事件和状态标志不同步 |
| 10 | **W7** | APIGateway try? 吞错误 | APIGateway.swift | JSON 序列化失败时无法排查 |
| 11 | **W13** | build.yml xcpretty 吞错误 | build.yml | CI 构建失败时无错误信息 |
| 12 | **W15+W21** | 多处 FileSystemService 使用默认路径 | FileExplorerView.swift, EditorState.swift | 项目路径不一致 |

### 🟢 P2 — 建议修复（代码风格/边界情况）

| 优先级 | 编号 | 问题 | 修复文件 |
|--------|------|------|---------|
| 13 | **W17** | Message.id hashValue 不稳定 | Message.swift（已用 stableHash 修复） |
| 14 | **W20** | AgentEvent.error(Error) 不 Sendable | AgentEvent.swift |
| 15 | **W11** | Tool inputSchema 不 Sendable | Tool.swift |
| 16 | **W3** | ToolResult.metadata 类型不一致 | ToolResult.swift |
| 17 | **W2** | KeychainService 错误映射 | KeychainService.swift |
| 18 | **W12** | ToolCallStatus 重复枚举 | ToolCallView.swift |
| 19 | **W18** | Package.swift exclude/resources 冲突 | Package.swift |
| 20 | **W14** | build.yml ldid -e 对 zip 无效 | build.yml |

### ⏭ 可延后（Phase 3 或更晚）

| 优先级 | 编号 | 问题 |
|--------|------|------|
| 21 | I3 | ToolCallEquality 忽略 arguments |
| 22 | I4 | ConversationSession projectPath 是 let |
| 23 | I5 | DashboardView mock 数据 |

---

## 四、Phase 2 目标与路线图

### 总体目标

**从「代码骨架可编译」到「真机可用可交付」**

Phase 1 交付了完整代码骨架 + CI/CD 流水线，但：
- 未在真机上运行过
- Monaco Editor 是 placeholder
- 服务实例每次重建（W22+W5）
- 无超时保护（W8）
- 仅支持 OpenAI API

Phase 2 聚焦：**修复致命缺陷 → 真机验证 → 多模型支持 → 编辑器可用**

### Phase 2 四个子阶段

```
Phase 2A: 稳定性修复（W22+W5, W8, W19, W6）        ~1 周
Phase 2B: 真机构建 + 基础验证（T2, T4, T5）          ~1 周
Phase 2C: 多模型支持（APIGateway 抽象 + 3 Provider）  ~2 周
Phase 2D: Monaco Editor 真实集成（GCDWebServer + npm包） ~1 周
```

### Phase 2A：稳定性修复（最高优先）

**目标**：修复 4 个 P0 Warning，让 Agent Loop 真正可用

| 任务 | 描述 | 涉及文件 |
|------|------|---------|
| 2A-1 | **DI 重构**：BaizeApp 创建共享服务实例 → 通过 Environment 注入到 ChatView | BaizeApp.swift, ChatView.swift, AppState.swift |
| 2A-2 | **超时机制**：RuntimeExecutor.spawnProcess 加入 30s 超时 + 取消支持 | RuntimeExecutor.swift, AgentLoop.swift |
| 2A-3 | **continuation 生命周期**：修复双重 finish + 错误路径处理 | AgentLoop.swift |
| 2A-4 | **SSE 多行 data**：按 SSE 规范用 `\n` 连接多行 data 字段 | SSEStream.swift |

### Phase 2B：真机构建 + 基础验证

**目标**：通过 GitHub Actions 构建 IPA → TrollStore 安装 → 基础功能验证

| 任务 | 描述 |
|------|------|
| 2B-1 | 修复 build.yml（W13, W14, W18）确保 CI 构建成功 |
| 2B-2 | 嵌入 nodejs-mobile arm64 二进制到 App Bundle |
| 2B-3 | 嵌入 Python 3.13+ XCFramework |
| 2B-4 | IPA 构建 → TrollStore 安装 → App 启动验证 |
| 2B-5 | T2 实测：ios_system 文件访问范围 |
| 2B-6 | T4 实测：Node.js 主进程稳定性（循环 50 次） |
| 2B-7 | T5 实测：Monaco placeholder + Agent Loop 并发性能 |

### Phase 2C：多模型支持

**目标**：支持 OpenAI + Anthropic + OpenRouter 三种 Provider

| 任务 | 描述 |
|------|------|
| 2C-1 | 定义 `LLMProvider` 协议（streamComplete, supportsFunctionCalling） |
| 2C-2 | 重构 APIGateway 为 Provider 注册机制 |
| 2C-3 | 实现 AnthropicProvider（Content Block 格式 + SSE） |
| 2C-4 | 实现 OpenRouterProvider（OpenAI 兼容格式 + 路由参数） |
| 2C-5 | ModelSettingsView 支持 Provider 选择 + 模型列表 |
| 2C-6 | APIKeySettingsView 支持 Anthropic/OpenRouter 密钥 |

### Phase 2D：Monaco Editor 真实集成

**目标**：替换 placeholder，实现真正的代码编辑功能

| 任务 | 描述 |
|------|------|
| 2D-1 | 下载 Monaco Editor npm 包，打包为 Bundle 资源 |
| 2D-2 | 集成 GCDWebServer 提供本地 Monaco 资源服务 |
| 2D-3 | 更新 MonacoBridge 适配真实 Monaco API |
| 2D-4 | 实现文件打开/保存/语法高亮/基本补全 |
| 2D-5 | 主题适配（VS Code 暗色主题 → 白泽风格） |

---

## 五、Phase 3 展望（后续规划）

基于 PRD 中的 P2 需求池和 8 份分析报告，Phase 3 的核心方向：

| 方向 | 功能 | 参考来源 |
|------|------|---------|
| **Memory 系统** | 工作记忆 + 短期记忆 + 长期记忆（SQLite + sqlite-vec） | mem0, langmem 分析 |
| **Skill 系统** | Markdown+YAML 技能模板，语义自动匹配 | skillkit, openskills 分析 |
| **Planning 系统** | DAG 目标图 + 自适应调度 + 只读规划模式 | goalweaver, saber 分析 |
| **MCP Client** | Swift MCP SDK 实现工具扩展协议 | PRD P1-10 |
| **Git 集成** | libgit2 或 shell 调用 git 命令 | PRD Phase 2 排除项 |
| **终端 UI** | 独立终端面板，替换对话面板中的命令输出 | 架构设计 Phase 2 |
| **Prompt 防御** | 12 攻击向量检测（纯正则，<5ms） | agent-governance-toolkit 分析 |
| **ABAC 策略引擎** | 5 Scope + 7 层优先级 + tokenized argv | ai-abacus 分析 |
| **子 Agent 委派** | Coordinator 模式，最小权限隔离 | claude-code, ADK 分析 |

---

*文档结束。本规划基于 Phase 1 全部交付物 + 8 份分析报告 + 技术调研制定。*
