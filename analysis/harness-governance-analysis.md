# Harness & Governance 源码深度分析报告

> 分析范围：HarnessX、OpenHarness、OpenViking、autoharness、agent-governance-toolkit、OPA、oh-my-kiro

---

## 1. HarnessX

### 1.1 项目概述

HarnessX 是一个**可组合的 Python Agent Harness 框架**，用于运行 LLM Agent 并收集训练轨迹（trajectories）。核心循环：`Harness.run(task)` -> `run_loop()` -> `StatefulTrajectory` + `HarnessResult`。

### 1.2 架构概览

HarnessX 将 Agent 行为组织为 **9 个正交行为维度**，映射到三大支柱：

- **Compose（组合）**：Model、Context、Memory、Tools、Sandbox
- **Adapt（适应）**：Evaluate、Control
- **Evolve（进化）**：Observe、Train

所有行为通过 **8 个 Hook 点的事件驱动 Processor Pipeline** 实现：

```
User request -> Harness.run(BaseTask) -> run_loop()
  ├── Processors 组装上下文 -> 发送消息给模型
  ├── provider.complete() -> ModelResponseEvent
  ├── tool_registry.execute() -> ToolResultEvent
  └── EvaluationProcessor -> 回填轨迹奖励
```

核心类/接口：
- `HarnessConfig`：行为管道配置（不含模型）
- `ModelConfig`：模型绑定（与 HarnessConfig 完全解耦）
- `HarnessBuilder`：Builder 模式，支持 `|` 管道组合
- `MultiHookProcessor`：单对象多 Hook 注册
- `StatefulTrajectory`：带奖励标注的执行轨迹
- `HarnessJournal`：JSONL 追踪 + OpenTelemetry

### 1.3 Agent Harness 设计

HarnessX 的 Harness 设计核心是**处理器管道**（Processor Pipeline）+ **Hook 点**机制：

1. **Hook 点**：`before_model`、`after_model`、`before_tool`、`after_tool`、`step_end`、`task_end` 等
2. **组合语法**：`HarnessBuilder() | context | coding` — 管道式组合，有冲突检测
3. **Bundle 系统**：`make_coding()`, `make_reliability()` 等预打包配置
4. **中断/恢复**：`interrupt_on=["send_message"]` 支持人机交互中断
5. **工作区隔离**：`Workspace(root=..., mode="isolated")`

### 1.4 Governance/Policy

- **13 个 Control Processor**：循环检测（LoopDetection）、成本守卫（CostGuard）、上下文压缩（Compaction）、迎合检测（SycophancyCheck）
- **退出原因**：`done | budget_exceeded | loop_detected | error`
- **Token 预算和成本限制**：`max_steps`, `token_budget`, `max_cost_usd`

### 1.5 Safety

- 循环检测处理器防止无限循环
- 成本守卫防止超支
- Sandbox 隔离（Local / Docker / E2B 云端）
- 中断机制支持人机审批

### 1.6 Evaluation/Benchmarking

- **多基准适配器**：GAIA、SWE-bench、LocoMo、Terminal Bench 2、TAU-2
- **LLM Judge / SelfVerify / PRM** 评估器
- **训练数据收集**：`trajectory.to_training_records()` — OpenAI chat 格式 + reward
- **评估结果**：`EvalResult(passed, score, reward)`

### 1.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| Processor Pipeline + Hook | 高 | iOS 可用 Protocol + 闭包实现轻量 Hook 链 |
| HarnessConfig / ModelConfig 分离 | 高 | iOS 本地模型 vs 云端模型可动态切换 |
| Bundle 组合语法 | 中 | iOS 可用 Extension 点机制实现类似效果 |
| Sandbox 隔离 | 高 | iOS 沙盒天然支持，可映射为 App Group |
| 中断/恢复 | 高 | iOS 可用 async/await + continuation 实现 |
| 13 个 Control Processor | 高 | 成本守卫、循环检测等在本地尤其重要 |

---

## 2. OpenHarness (oh)

### 2.1 项目概述

OpenHarness 是一个**开源轻量级 Agent 基础设施**，提供工具调用、技能、记忆和多 Agent 协调。核心命令 `oh` 启动完整 Harness。由香港大学 HKUDS 团队开发。

### 2.2 架构概览

核心模块：
- `src/openharness/api/`：多 Provider 客户端（Anthropic、OpenAI、Codex、Copilot）
- `src/openharness/auth/`：认证管理（多 Profile、外部认证）
- `src/openharness/bridge/`：桥接层（会话运行器、工作密钥）
- `src/openharness/channels/`：多渠道适配（飞书、Slack、Discord、钉钉、QQ、邮件等）
- `src/openharness/autopilot/`：自动巡航模式
- `frontend/terminal/`：React + Ink TUI 前端
- `ohmo/`：个人 AI Agent 应用（网关、会话存储、工作区）

### 2.3 Agent Harness 设计

OpenHarness 的 Harness 方程式：

**Harness = Tools + Knowledge + Observation + Action + Permissions**

五大 Harness 特性：
1. **Agent Loop**：流式工具调用循环、API 重试、并行工具执行、Token 计数和成本追踪
2. **Harness Toolkit**：43+ 工具（文件、Shell、搜索、Web、MCP）、按需技能加载、插件生态
3. **Context & Memory**：CLAUDE.md 发现与注入、上下文压缩（Auto-Compact）、MEMORY.md 持久记忆、会话恢复
4. **Governance**：多级权限模式、路径级和命令规则、PreToolUse/PostToolUse Hook、交互式审批
5. **Swarm Coordination**：子 Agent 生成与委托、团队注册表、后台任务生命周期

### 2.4 Governance/Policy

- **多级权限模式**：从完全自动到手动审批
- **路径级规则**：限制文件系统访问范围
- **命令规则**：限制 Shell 命令执行
- **PreToolUse / PostToolUse Hook**：工具执行前后的拦截和验证
- **交互式审批对话框**：敏感操作需要用户确认
- **敏感路径保护**：`PermissionChecker` 内建敏感路径防护
- **Dry-run 模式**：`oh --dry-run` 预览运行时设置、认证状态、工具配置

### 2.5 Safety

- URL 验证加固（`web_fetch` URL validation）
- MCP 断线优雅处理
- 权限序列化防止输入吞噬
- EIO 崩溃恢复（Ink TUI）

### 2.6 Evaluation/Benchmarking

- 114 个通过测试、6 个 E2E 套件
- CI 工作流包含自动化测试

### 2.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| Harness 方程式 | 高 | iOS Agent 可按此五要素设计 |
| 多渠道适配 | 高 | iOS 可适配 Shortcuts、Widget、Siri |
| Auto-Compact | 高 | 本地内存受限，自动压缩上下文至关重要 |
| 权限 Hook 机制 | 高 | iOS 可用 BackgroundTask + 用户确认实现 |
| MCP 协议 | 中 | iOS 上 MCP 客户端可实现但进程模型不同 |
| Dry-run 模式 | 高 | 预览模式对安全敏感的本地操作非常有价值 |
| 技能按需加载 | 高 | iOS 内存有限，按需加载 Markdown 技能文件很合适 |

---

## 3. OpenViking

### 3.1 项目概述

OpenViking 是一个**完整的企业级 AI Agent 平台**，包含 Bot 框架、多渠道接入、子 Agent 管理、记忆系统、MCP 工具集成和 Web Studio 管理界面。与 OpenHarness 同属 HKUDS 生态。

### 3.2 架构概览

核心模块：
- `bot/vikingbot/agent/`：Agent 核心（loop.py、context.py、memory.py、skills.py、subagent.py）
- `bot/vikingbot/agent/tools/`：工具系统（Shell、Filesystem、MCP、WebSearch、Image、Spawn 等）
- `bot/vikingbot/channels/`：多渠道适配
- `bot/vikingbot/bus/`：消息总线（InboundMessage / OutboundMessage）
- `bot/vikingbot/hooks/`：Hook 管理器
- `bot/vikingbot/sandbox/`：沙盒管理
- `bot/vikingbot/session/`：会话管理
- `benchmark/`：LocoMo 基准测试
- `web-studio/`：Web 管理界面（TypeScript + Vite）

### 3.3 Agent Harness 设计

OpenViking 的 AgentLoop 是核心处理引擎：

1. **消息接收**：从 Bus 消费 InboundMessage
2. **上下文构建**：ContextBuilder 组装历史、记忆、技能
3. **LLM 调用**：支持流式输出（content_delta、reasoning_delta）
4. **工具执行**：并行执行所有工具调用
5. **响应发送**：通过 Bus 发布 OutboundMessage

**SubagentManager** 管理 Agent 生成：
- 子 Agent 共享 LLM Provider，但有隔离上下文和聚焦系统提示
- 限制最大迭代次数（15 次）
- 子 Agent 没有消息工具和 Spawn 工具（防止无限嵌套）
- 通过 `announce_content` 机制回报结果

**OpenViking Session Context**：
- 服务端会话管理，支持跨会话记忆持久化
- 自动提交阈值（基于 token 数和消息数）
- 会话压缩和记忆整合

### 3.4 Governance/Policy

- **命令授权检查**：`_check_cmd_auth()` 基于 `allow_from` 列表
- **Bot 模式**：NORMAL、DEBUG、READONLY
- **禁用工具列表**：`disabled_tools` 元数据控制
- **Hook 系统**：`message.compact` 等事件触发 Hook

### 3.5 Safety

- 沙盒管理器（SandboxManager）隔离文件系统访问
- 最大迭代限制防止无限循环
- 子 Agent 工具白名单（无消息、无生成）
- 长时间运行通知机制（每 60 秒发送处理中提示）

### 3.6 Evaluation/Benchmarking

- **LocoMo 基准测试**：对比 Claude Code、Hermes、OpenClaw、mem0、SuperMemory 等方案
- **Judge 评估**：LLM-as-Judge 评判回答质量
- **统计工具**：`stat_judge_result.py` 分析评估结果

### 3.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| MessageBus 架构 | 高 | iOS 可用 Combine/AsyncStream 实现类似消息总线 |
| AgentLoop 模式 | 高 | 核心循环模式直接适用于 iOS |
| SubagentManager | 高 | iOS 可用 actor 模型实现轻量子 Agent |
| Session 管理 | 高 | iOS UserDefaults + FileManager 持久化会话 |
| 流式输出 | 高 | SwiftUI 可直接消费 async stream |
| 经验记忆注入 | 高 | 写操作前自动注入相关经验，提升本地 Agent 学习能力 |
| 并行工具执行 | 中 | iOS GCD 可并行执行，但需注意线程安全 |

---

## 4. autoharness

### 4.1 项目概述

autoharness 是一个**Agent Harness 框架的安装和管理工具**，提供工作区发现、验证、以及与 VS Code Copilot、Claude Code、Codex 的集成。核心理念：**AI 编码助手本身就是运行时**，autoharness 负责安装和验证 Harness 配置。

### 4.2 架构概览

核心文件：
- `.autoharness/config.yaml`：Harness 配置（schema 版本化、预设、能力包、模型路由）
- `.autoharness/harness-manifest.yaml`：安装清单（校验和、原语层级、能力包覆盖）
- `.autoharness/workspace-profile.yaml`：工作区画像（语言、框架、构建工具、CI、代码规范）
- `src/autoharness/cli.py`：CLI 入口
- `src/autoharness/schema_contracts.py`：Schema 契约和迁移
- `src/autoharness/verify_workspace.py`：工作区验证

### 4.3 Agent Harness 设计

autoharness 的 Harness 设计围绕**声明式配置 + 验证**：

1. **安装预设（Preset）**：`full`、`minimal` 等
2. **能力包（Capability Packs）**：`agent-intercom`、`backlogit`、`agent-engram`、`graphtor-docs`
3. **安装层级（Install Layers）**：foundation、instructions、workflow、review、runtime、backlog、knowledge、overlays
4. **工作区发现**：自动检测语言、框架、构建工具
5. **Schema 契约**：版本化 Schema、兼容性模型、迁移提案
6. **模型路由**：Tier 1/2/3 + 编排者模型

### 4.4 Governance/Policy

- **Schema 契约验证**：版本化 Schema 确保 Harness 配置正确
- **分类错误处理**：strict_schema_blocker（硬阻断）vs warning（兼容性漂移）
- **迁移提案系统**：`CONTRACT_MIGRATIONS` 自动建议升级路径
- **完整性验证**：`verify-workspace` 命令确定性验证已安装 Harness

### 4.5 Safety

- 校验和（SHA-256）验证所有已安装构件
- Schema 版本化防止配置漂移
- 原语层级控制安装深度
- 变量占位符检测（未解析的 `{{VARIABLE}}`）

### 4.6 Evaluation/Benchmarking

- 工作区验证报告：blockers、warnings、migration proposals、unresolved placeholders
- 支持输出 Markdown 和 JSON 格式

### 4.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| 声明式 Harness 配置 | 高 | iOS 可用 plist/JSON 定义 Agent 配置 |
| 工作区画像 | 高 | 自动检测 Xcode 项目、Swift 版本等 |
| Schema 契约 + 版本迁移 | 高 | iOS Agent 配置需要版本化升级机制 |
| 能力包系统 | 中 | iOS 可用 Feature Flag + Extension 实现类似功能 |
| 模型路由 | 高 | iOS 可根据任务复杂度路由到本地/云端模型 |
| 校验和验证 | 高 | iOS 可验证 Agent 配置完整性 |

---

## 5. agent-governance-toolkit (Microsoft)

### 5.1 项目概述

Microsoft 的 **Agent 治理工具包**，提供策略评估、Prompt 防御审计、完整性验证、供应链安全和治理认证。这是一个企业级治理框架，映射 OWASP LLM Top 10 / ASI 控制标准。

### 5.2 架构概览

核心模块：
- `policy_test.py`：策略回归测试引擎（fixture 回放）
- `prompt_defense.py`：Prompt 防御评估器（12 个攻击向量）
- `integrity.py`：引导完整性验证（文件哈希 + 字节码哈希）
- `verify.py`：治理验证与认证（OWASP ASI 10 项控制检查）
- `supply_chain.py`：供应链安全
- `security/scanner.py`：安全扫描
- `promotion.py`：提升策略
- `lint_policy.py`：策略 lint

### 5.3 Agent Harness 设计

agent-governance-toolkit 不是一个 Harness 框架本身，而是 Harness 的**治理层**：

1. **治理验证器（GovernanceVerifier）**：检查 10 项 OWASP ASI 控制是否已安装
2. **运行时证据验证**：`verify_evidence()` 验证策略文件、工具注册、审计接收器、身份、包清单
3. **治理认证（GovernanceAttestation）**：生成签名的认证报告
4. **CI 门禁**：`agt test` 命令用于 CI 管道

### 5.4 Governance/Policy

**OWASP ASI 10 项控制**：

| 控制ID | 名称 | 模块 |
|--------|------|------|
| ASI-01 | Prompt Injection | PolicyInterceptor |
| ASI-02 | Insecure Tool Use | ToolAliasRegistry |
| ASI-03 | Excessive Agency | GovernancePolicy |
| ASI-04 | Unauthorized Escalation | EscalationPolicy |
| ASI-05 | Trust Boundary Violation | CardRegistry |
| ASI-06 | Insufficient Logging | AuditChain |
| ASI-07 | Insecure Identity | AgentIdentity |
| ASI-08 | Policy Bypass | PolicyConflictResolver |
| ASI-09 | Supply Chain Integrity | IntegrityVerifier |
| ASI-10 | Behavioral Anomaly | ComplianceEngine |

**策略回归测试**：`replay()` 函数加载 JSON/YAML fixture，对当前策略求值，报告判决不匹配。

**Prompt 防御评估**（12 个攻击向量）：

| 向量 | OWASP | 说明 |
|------|-------|------|
| role-escape | LLM01 | 角色边界防护 |
| instruction-override | LLM01 | 指令边界防护 |
| data-leakage | LLM07 | 数据保护 |
| output-manipulation | LLM02 | 输出控制 |
| multilang-bypass | LLM01 | 多语言防护 |
| unicode-attack | LLM01 | Unicode 防护 |
| context-overflow | LLM01 | 长度限制 |
| indirect-injection | LLM01 | 间接注入防护 |
| social-engineering | LLM01 | 社工防御 |
| output-weaponization | LLM02 | 有害内容预防 |
| abuse-prevention | LLM06 | 滥用预防 |
| input-validation | LLM01 | 输入验证 |

评分体系：A(>=90) / B(>=70) / C(>=50) / D(>=30) / F(<30)

### 5.5 Safety

- **引导完整性验证**：SHA-256 哈希文件 + 函数字节码（`marshal.dumps(func.__code__)`）
- **Fail-closed 语义**：损坏的 manifest 拒绝启动，缺失条目视为失败
- **模块白名单**：只允许 AGT 拥有的命名空间动态导入
- **Merkle 审计链**：审计日志的密码学完整性
- **路径穿越防护**：`_resolve_reported_paths` 防止路径逃逸
- **ReDoS 防护**：Prompt 长度上限 100KB，正则回溯限制 50 字符

### 5.6 Evaluation/Benchmarking

- 策略回归测试 fixture 系统
- Prompt 防御评分体系
- OWASP ASI 覆盖率百分比
- Shields.io 徽章（CI 可视化）

### 5.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| OWASP ASI 控制检查 | 高 | iOS Agent 必须实现基础安全控制 |
| Prompt 防御评估 | 高 | 纯正则、零 LLM 成本，<5ms，iOS 可直接移植 |
| 引导完整性验证 | 高 | iOS 可用 Code Signing 实现更可靠的完整性验证 |
| Fail-closed 语义 | 高 | 安全关键场景必须 fail-closed |
| 策略回归测试 | 高 | fixture 回放模式可用于 iOS Agent 测试 |
| 治理认证 | 中 | iOS 本地 Agent 可简化认证流程 |
| 运行时证据 | 中 | iOS 可收集简化版运行时证据用于调试 |

---

## 6. OPA (Open Policy Agent)

### 6.1 项目概述

OPA 是一个**通用的策略引擎**，使用 Rego 语言声明策略，可嵌入应用或作为独立服务运行。OPA 本身不是 Agent 框架，而是 Agent 治理的基础设施层——提供策略即代码（Policy as Code）能力。

### 6.2 架构概览

OPA 核心组件（Go 语言）：
- `ast/`：抽象语法树、解析器、编译器
- `rego/`：Rego 语言引擎
- `storage/`：策略数据存储
- `topdown/`：自顶向下评估器
- `server/`：HTTP API 服务
- `bundle/`：策略打包和分发
- `plugins/`：插件系统（决策日志、状态等）
- `wasm/`：WebAssembly 编译和执行

### 6.3 Agent Harness 设计

OPA 不提供 Agent Harness，但可嵌入 Harness 作为**策略决策层**：

1. **策略即代码**：Rego 语言声明策略规则
2. **嵌入式评估**：Go 库嵌入应用，无网络调用
3. **WASM 编译**：策略编译为 WASM，可在任何平台运行
4. **Bundle 机制**：策略打包和版本化分发

### 6.4 Governance/Policy

OPA 是治理/策略的**参考实现**：

- **声明式策略**：Rego 语言表达复杂策略逻辑
- **部分评估**：未知值的部分求值
- **策略组合**：多个策略文件组合
- **增量更新**：热重载策略
- **审计日志**：所有决策可追溯

### 6.5 Safety

- 沙盒执行环境
- 资源限制（超时、内存）
- 只读数据访问
- 决策日志不可篡改

### 6.6 Evaluation/Benchmarking

- 基准测试框架
- 回归测试套件
- 性能基准

### 6.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| 策略即代码 | 高 | iOS 可用 Swift DSL 定义 Agent 策略 |
| 嵌入式评估 | 高 | iOS 可嵌入轻量策略引擎（无需网络） |
| WASM 编译 | 中 | iOS 可通过 WasmEdge/WasmKit 运行编译后的策略 |
| Bundle 机制 | 高 | iOS 可用 Asset Catalog + 版本化策略包 |
| 声明式策略 | 高 | Rego 的声明式风格可映射为 Swift Result Builder |

---

## 7. oh-my-kiro

### 7.1 项目概述

oh-my-kiro 是一个**Kiro IDE 的多 Agent 编排系统**，提供结构化的规划-执行分离工作流，3 个主 Agent + 7 个子 Agent，通过文件系统的计划文件作为唯一的交接工件。

### 7.2 架构概览

**3 个主 Agent**：
- **Phantom**（ctrl+p）：规划者，访谈用户、委托研究、生成计划文件
- **Revenant**（ctrl+a）：执行者，读取计划文件、委托实现、独立验证
- **Wraith**（ctrl+e）：直接执行者，处理不需要规划的快速任务

**7 个子 Agent**：
- ghost-explorer：代码库探索
- ghost-analyst：计划前分析（Phantom 强制执行）
- ghost-validator：计划后验证（Phantom 可选执行）
- ghost-researcher：技术研究（MCP 驱动的 Web 搜索）
- ghost-oracle：战略顾问和调试升级
- ghost-reviewer：代码审查
- ghost-implementer：任务实现（写代码）

**核心工件**：
- `.kiro/plans/{name}.md`：计划文件（规划与执行的唯一交接）
- `.kiro/notepads/`：跨 Agent 共享记忆
- `.kiro/steering/`：共享上下文（product.md、conventions.md、architecture.md）
- `.kiro/skills/`：按需加载的技能文件

### 7.3 Agent Harness 设计

oh-my-kiro 的 Harness 设计围绕**约束驱动**：

1. **主 Agent 不写代码**：Phantom 只规划，Revenant 只委托，Wraith 可处理简单任务
2. **文件系统即交接**：计划文件是唯一 handoff artifact
3. **6 段委托格式**：TASK、EXPECTED OUTCOME、REQUIRED TOOLS、MUST DO、MUST NOT DO、CONTEXT
4. **Steering 文件**：共享的项目上下文，所有 Agent 可读
5. **计划生命周期**：DRAFT -> READY -> IN_PROGRESS -> COMPLETE

### 7.4 Governance/Policy

**三层安全防护**：

1. **JSON 配置权限**：
   - `tools`：Agent 可用的工具列表
   - `allowedPaths`：文件系统路径限制
   - `toolsSettings.subagent.availableAgents`：可委托的子 Agent 列表

2. **Shell Hook 运行时执行**：
   - `agent-spawn.sh`：Agent 启动时注入 git 状态 + 计划上下文
   - `pre-tool-use.sh`：阻止计划文件删除和 `.kiro/` 目录破坏
   - `phantom-read-guard.sh`：警告 Phantom 直接读项目文件（应委托 ghost-explorer）
   - `phantom-write-guard.sh`：阻止 Phantom 写 `.kiro/plans/` 和 `.kiro/notepads/` 以外的文件

3. **身份强化**：每个 Agent 的 prompt 中反复强调其角色和约束

### 7.5 Safety

- 路径级写入限制（allowedPaths）
- 工具使用限制（allowedTools）
- 子 Agent 委托白名单
- Hook 执行超时（5-10 秒）
- 计划文件 gitignore（运行时工件不提交）

### 7.6 Evaluation/Benchmarking

无专门的基准测试系统。

### 7.7 对 iOS 本地 Agent 的启示

| 设计模式 | 适用性 | 说明 |
|---------|--------|------|
| 规划-执行分离 | 高 | iOS Agent 可区分规划阶段和执行阶段 |
| 6 段委托格式 | 高 | 结构化委托可在 iOS 上用 Codable 实现 |
| 文件系统交接 | 中 | iOS 可用 App Group 共享容器 + FileManager |
| 三层安全防护 | 高 | JSON 配置 + Hook + 身份强化可移植到 iOS |
| Steering 文件 | 高 | iOS Agent 可读取项目级上下文文件 |
| 计划生命周期 | 高 | SwiftUI @Observable 可驱动计划状态 UI |
| Notepads 跨 Agent 记忆 | 高 | iOS 可用 App Group 共享文件实现 |

---

## 跨项目综合分析

### Harness 设计模式总结

| 模式 | HarnessX | OpenHarness | OpenViking | autoharness | oh-my-kiro |
|------|----------|-------------|------------|-------------|------------|
| 事件驱动管道 | Processor+Hook | PreToolUse/PostToolUse Hook | HookManager | Schema Contract | Shell Hook |
| 声明式配置 | HarnessConfig+YAML | 多级权限 | Config Schema | config.yaml | JSON Agent Config |
| 模型解耦 | ModelConfig 独立 | Provider Registry | LLMProvider | model_routing | Kiro IDE 内置 |
| 工作区隔离 | Workspace(isolated) | PermissionChecker | SandboxManager | workspace-profile | allowedPaths |
| 记忆管理 | 5 策略 | MEMORY.md+AutoCompact | OpenViking Session+Experience | N/A | Notepads |
| 中断/恢复 | interrupt_on | 交互式审批 | N/A | N/A | N/A |

### Governance 设计模式总结

| 模式 | HarnessX | OpenHarness | agent-governance-toolkit | OPA | oh-my-kiro |
|------|----------|-------------|------------------------|-----|------------|
| 策略即代码 | Processor配置 | 规则配置 | YAML Policy | Rego | JSON Config |
| 静态分析 | N/A | N/A | Prompt Defense 12向量 | N/A | N/A |
| 完整性验证 | N/A | N/A | SHA-256+字节码 | N/A | N/A |
| 审计追踪 | HarnessJournal | N/A | MerkleAuditChain | Decision Log | N/A |
| OWASP映射 | N/A | N/A | ASI 10控制 | N/A | N/A |
| 回归测试 | 评估器 | 114测试 | Fixture回放 | Rego测试 | N/A |
| Fail-closed | 循环检测 | N/A | Manifest损坏拒绝启动 | N/A | N/A |

### 对 iOS 本地 Agent 的最高优先级设计建议

1. **采用 HarnessX 的 Processor Pipeline 模式**：用 Swift Protocol + async sequence 实现 Hook 链，支持 beforeModel、afterModel、beforeTool、afterTool 等 Hook 点

2. **采用 agent-governance-toolkit 的 Prompt 防御评估器**：纯正则实现，<5ms 延迟，12 个攻击向量覆盖 OWASP LLM Top 10，直接移植到 Swift

3. **采用 oh-my-kiro 的三层安全防护**：JSON 配置权限 + Shell Hook 等效的 Swift 方法拦截 + 身份强化提示

4. **采用 OpenHarness 的 Auto-Compact 模式**：iOS 内存受限，必须在上下文超限时自动压缩

5. **采用 autoharness 的 Schema 契约系统**：版本化配置 + 迁移提案，确保 Agent 配置在不同 iOS 版本间兼容

6. **采用 OPA 的策略即代码理念**：用 Swift DSL（Result Builder）定义 Agent 策略，嵌入式评估无需网络

7. **采用 OpenViking 的经验记忆注入**：写操作前自动检索相关经验，提升本地 Agent 学习效率
