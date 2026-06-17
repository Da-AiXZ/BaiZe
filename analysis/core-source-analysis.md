# 核心源码深度分析报告

> 分析对象：claude-code、ADK Python、ADK Dart
> 分析日期：2026-06-17
> 分析方法：深入阅读核心源码文件，不依赖 README 概述

---

## 一、claude-code

### 1. 项目概述

claude-code 是 Anthropic 的终端原生 AI 编码助手，基于 Bun 运行时构建。它使用 React + Ink 在终端中渲染交互式 UI，通过 Commander.js 解析 CLI 参数。核心管道为：`User Input → CLI Parser → Query Engine → LLM API → Tool Execution Loop → Terminal UI`。

**技术栈**：TypeScript + Bun + React/Ink + Zod（schema 验证）+ lodash-es

**核心源码文件**：
- `src/QueryEngine.ts`（~1297 行）：查询引擎入口
- `src/query.ts`（~1730 行）：Agent loop 核心实现
- `src/Tool.ts`（~794 行）：Tool 接口定义和 `buildTool` 工厂
- `src/tools.ts`（~397 行）：工具注册和组装
- `src/context.ts`（~190 行）：系统和用户上下文管理
- `src/services/compact/compact.ts`（~1706 行）：上下文压缩服务
- `src/coordinator/coordinatorMode.ts`（~369 行）：多 Agent 协调模式

### 2. 架构概览

claude-code 采用**单线程事件循环**架构，所有 I/O 操作通过 async/await 在 Bun 事件循环中调度。

```
┌─────────────────────────────────────────────┐
│                 CLI / REPL                   │
│            (Commander.js + Ink)              │
├─────────────────────────────────────────────┤
│              QueryEngine.ts                   │
│  ┌──────────────────────────────────────┐   │
│  │            query.ts                   │   │
│  │  ┌─────────┐  ┌──────────┐  ┌─────┐ │   │
│  │  │ Streaming│→ │Tool Loop │→ │Compact│   │
│  │  └─────────┘  └──────────┘  └─────┘ │   │
│  └──────────────────────────────────────┘   │
├─────────────────────────────────────────────┤
│        Tool System (tools.ts + Tool.ts)      │
│   buildTool() → Zod Schema → Permissions    │
├─────────────────────────────────────────────┤
│          Context & Memory Layer              │
│   CLAUDE.md + Git Status + Compact Service   │
├─────────────────────────────────────────────┤
│          Coordinator (可选)                  │
│   AgentTool + SendMessage + TaskStop          │
└─────────────────────────────────────────────┘
```

**Feature Flags 死代码消除**：通过 `feature('FLAG_NAME')` 和 `bun:bundle`，在构建时移除未启用的功能代码路径。例如 `feature('COORDINATOR_MODE')`、`feature('CONTEXT_COLLAPSE')` 等。这确保了生产构建不包含未使用功能的代码。

### 3. Agent Loop 机制

Agent Loop 的核心实现在 `src/query.ts`（~1730 行），是整个系统的心脏。

**循环流程**：
1. 接收用户输入或工具结果
2. 调用 LLM API（支持 streaming）
3. 解析 LLM 响应中的 tool_use blocks
4. 对每个 tool_use 执行权限检查 → 验证输入 → 执行工具 → 收集结果
5. 将工具结果作为 user 消息追加到对话
6. 检查是否需要 auto-compact（基于 token 阈值）
7. 如果有更多 tool_use，回到步骤 2；否则返回最终响应

**关键设计**：
- **Auto-compact 逻辑**：当 token 使用量接近阈值时自动触发压缩。`isAutoCompactEnabled` 检查是否启用，`buildPostCompactMessages` 构建压缩后的消息序列。
- **Context Collapse**：通过 `feature('CONTEXT_COLLAPSE')` 标志启用，允许折叠历史上下文以节省 token。
- **Token Warning State**：`calculateTokenWarningState` 实时跟踪 token 使用量，在接近限制时向用户发出警告。
- **Retry 逻辑**：API 调用失败时，通过 `getRetryDelay` 计算退避时间，支持指数退避重试。

**Streaming 机制**：
QueryEngine 使用 `queryModelWithStreaming` 获取流式响应。流式事件类型包括：
- `content_block_start`：内容块开始
- `content_block_delta`：内容增量（text_delta）
- `assistant`：完整的助手消息

流式过程中通过 `setStreamMode('responding')` 和 `setResponseLength` 回调更新 UI。

### 4. Tool System

**Tool 接口**（`src/Tool.ts`）：

每个工具是一个自包含对象，具有以下核心属性：
```typescript
interface Tool {
  name: string;
  async description(args): string;
  inputSchema: ZodSchema;          // Zod 输入验证
  validateInput(input, context): ValidationResult;
  checkPermissions(input, context): PermissionResult;
  isConcurrencySafe(): boolean;    // 是否可并行执行
  isReadOnly(): boolean;          // 是否只读
  isDestructive(): boolean;        // 是否破坏性操作
  shouldDefer(): boolean;         // 是否延迟加载
  alwaysLoad(): boolean;           // 是否总是加载
  maxResultSizeChars: number;      // 结果大小限制
  renderToolResultMessage(result): ReactElement;
  toAutoClassifierInput(): object; // 自动分类器输入
}
```

**`buildTool` 工厂函数**：使用 `TOOL_DEFAULTS` 填充安全默认值，采用 **fail-closed** 策略——未指定的属性默认为最安全选项（如 `isDestructive` 默认为 `true`，`isConcurrencySafe` 默认为 `false`）。

**ToolUseContext** 包含：
- `options`：工具配置（tools 列表、model、mcpClients 等）
- `abortController`：中止信号
- `readFileState`：文件读取状态缓存
- `getAppStates` / `setAppState`：应用状态访问器
- `onCompactProgress`：压缩进度回调

**工具注册**（`src/tools.ts`）：

`getAllBaseTools()` 返回所有基础工具数组，使用条件展开运算符根据 feature flags 动态包含/排除工具：
```typescript
return [
  AgentTool, TaskOutputTool, BashTool,
  ...(hasEmbeddedSearchTools() ? [] : [GlobTool, GrepTool]),
  ...(isTodoV2Enabled() ? [TaskCreateTool, TaskGetTool, ...] : []),
  ...(feature('COORDINATOR_MODE') ? [getSendMessageTool()] : []),
  // ...
]
```

**工具池组装**：`assembleToolPool(permissionContext, mcpTools)` 将内置工具与 MCP 工具合并，按名称排序以保持 prompt cache 稳定性，使用 `uniqBy` 去重（内置工具优先）。

**权限过滤**：`filterToolsByDenyRules` 在模型看到工具之前就移除被 deny 的工具，支持 MCP server 前缀匹配（如 `mcp__server` 移除整个 server 的工具）。

### 5. Context Management

**系统上下文**（`getSystemContext`，memoized）：
- Git 状态快照（分支、主分支、状态、最近 5 条 commit、用户名）
- 截断限制：状态超过 2000 字符时截断
- Cache breaker 注入（ant-only，用于调试）

**用户上下文**（`getUserContext`，memoized）：
- CLAUDE.md 文件内容（项目级、用户级、团队级）
- 当前日期
- 通过 `--bare` 模式可跳过自动发现，但仍尊重显式 `--add-dir`

**Compaction 服务**（`src/services/compact/compact.ts`，~1706 行）：

这是 claude-code 最复杂的子系统之一。支持两种压缩模式：

1. **全量压缩**（`compactConversation`）：
   - 执行 PreCompact hooks
   - 通过 `streamCompactSummary` 流式生成对话摘要
   - 使用 forked agent 路径复用主对话的 prompt cache（`runForkedAgent`）
   - 清空 `readFileState` 缓存
   - 恢复最近访问的文件（最多 5 个，每个 5000 token 上限，总预算 50000 token）
   - 恢复已调用的 Skills 内容（每个 5000 token 上限，总预算 25000 token）
   - 重新注入 deferred tools delta、agent listing delta、MCP instructions delta
   - 执行 SessionStart hooks 和 PostCompact hooks
   - 创建 compact boundary marker

2. **部分压缩**（`partialCompactConversation`）：
   - `direction: 'from'`：从指定消息开始向后压缩，保留早期消息（保持 prompt cache）
   - `direction: 'up_to'`：压缩到指定消息之前，保留后续消息（prompt cache 失效）
   - 支持用户反馈作为压缩指令

**PTL（Prompt Too Long）重试**：
当压缩请求本身超过 token 限制时，`truncateHeadForPTLRetry` 按 API 轮次分组消息，丢弃最早的分组直到覆盖 token gap，最多重试 3 次。无法解析 gap 时回退到丢弃 20% 的分组。

**Post-Compact 恢复**：
- 文件附件：从 `readFileState` 中按时间戳排序，重新读取文件内容
- Skill 附件：保留已调用 skill 的内容，按 token 预算截断
- Plan 附件：如果存在 plan 文件，保留引用
- Plan Mode 附件：如果在 plan mode 中，保留指令
- Async Agent 附件：保留运行中和已完成但未检索的 agent 状态
- Deferred Tools Delta：重新声明延迟加载的工具
- MCP Instructions Delta：重新声明 MCP 工具说明

### 6. Streaming

claude-code 使用 Anthropic SDK 的流式 API，通过 async generator 模式实现：

```typescript
const streamingGen = queryModelWithStreaming({...});
const streamIter = streamingGen[Symbol.asyncIterator]();
let next = await streamIter.next();
while (!next.done) {
  const event = next.value;
  // 处理 content_block_start, content_block_delta, assistant 事件
  next = await streamIter.next();
}
```

**UI 更新**：
- `setStreamMode('requesting' | 'responding')`：控制 UI 显示模式
- `setResponseLength(callback)`：实时更新响应长度
- 流式过程中首次检测到 text delta 时切换到 `responding` 模式

**Compaction 期间的 Keep-Alive**：
在 compaction API 调用期间（可能 5-10 秒），每 30 秒发送 session activity 信号和 `compacting` 状态，防止 WebSocket 空闲超时。

### 7. Memory

claude-code 的记忆系统基于 **CLAUDE.md 文件**：

- **项目级**：`.claude/CLAUDE.md` 或 `CLAUDE.md` 在项目根目录
- **用户级**：`~/.claude/CLAUDE.md`
- **团队级**：通过 `--add-dir` 指定的额外目录

`getMemoryFiles()` 发现并读取这些文件，`filterInjectedMemoryFiles` 过滤已注入的文件，`getClaudeMds` 合并内容。

**Memory 与 Compaction 的交互**：
- 压缩后，CLAUDE.md 内容会被排除在文件恢复列表之外（`shouldExcludeFromPostCompactRestore`），因为它们已通过 user context 重新注入
- `loadedNestedMemoryPaths` 在压缩后清空，允许重新发现嵌套记忆文件

**Scratchpad**（feature gated `tengu_scratch`）：
Coordinator 模式下，提供跨 worker 的持久化知识目录，worker 可读写无需权限提示。

### 8. Orchestration

**Coordinator 模式**（`src/coordinator/coordinatorMode.ts`）：

当 `CLAUDE_CODE_COORDINATOR_MODE` 环境变量启用时，claude-code 进入协调器模式。协调器不直接执行代码操作，而是：

1. **分发任务**：通过 `AgentTool` 创建 worker agent
2. **继续对话**：通过 `SendMessageTool` 向已有 worker 发送后续指令
3. **停止 worker**：通过 `TaskStopTool` 停止错误方向的 worker
4. **并行执行**：只读任务（研究）可并行；写入任务按文件集串行

**Coordinator System Prompt** 详细定义了：
- 角色定位（协调者，非执行者）
- 工具使用指南（何时 spawn vs continue）
- 任务工作流（Research → Synthesis → Implementation → Verification）
- Worker Prompt 编写指南（必须自包含，包含文件路径、行号、具体修改）
- 并发管理策略
- 失败处理流程

**Worker 工具集**：
- 标准模式：`ASYNC_AGENT_ALLOWED_TOOLS` 减去内部工具
- Simple 模式：Bash、FileRead、FileEdit
- 均可访问 MCP 工具

**Session Mode 匹配**：`matchSessionMode` 在 resume 会话时检测 coordinator 模式不匹配，自动切换环境变量以匹配会话存储的模式。

### 9. Policy / Governance

**权限模式**（4 种）：
1. `default`：标准模式，需要用户确认危险操作
2. `plan`：计划模式，只读分析，不执行修改
3. `bypassPermissions`：跳过所有权限检查
4. `auto`：自动模式，使用 `yoloClassifier` 自动分类工具调用

**权限检查流程**：
1. `filterToolsByDenyRules`：在工具注册阶段移除被 deny 的工具
2. `checkPermissions(input, context)`：运行时权限检查，返回 `allow`、`deny` 或 `ask`
3. `yoloClassifier`：auto 模式下使用 LLM 分类器判断是否自动允许

**Tool 安全属性**：
- `isConcurrencySafe`：是否可与其他工具并行执行
- `isReadOnly`：是否只读（不影响文件系统）
- `isDestructive`：是否破坏性（默认 true，fail-closed）
- `shouldDefer`：是否延迟加载（tool search 机制）
- `maxResultSizeChars`：结果大小限制，防止 token 泄露

**Compaction 期间的安全措施**：
`createCompactCanUseTool()` 返回始终 deny 的权限函数，确保 compaction agent 只生成文本摘要，不执行任何工具。

### 10. 关键技术决策

1. **Bun 运行时 + Feature Flags**：通过 `bun:bundle` 的 `feature()` 函数实现编译时死代码消除，生产构建不包含未启用功能的代码。这允许在单一代码库中维护企业版和社区版。

2. **Forked Agent for Compaction**：压缩时通过 `runForkedAgent` 创建 fork agent，复用主对话的 prompt cache prefix（system prompt + tools + context messages），避免重复计算和缓存失效。

3. **Prompt Cache 稳定性**：`assembleToolPool` 中对工具按名称排序，保持内置工具作为连续前缀。这确保 MCP 工具不会插入到内置工具之间，导致 prompt cache key 失效。

4. **Fail-Closed 安全默认值**：`buildTool` 的 `TOOL_DEFAULTS` 将 `isDestructive` 默认为 `true`、`isConcurrencySafe` 默认为 `false`，确保未明确标注的工具按最安全方式处理。

5. **Lazy Require 破坏循环依赖**：`tools.ts` 中 `TeamCreateTool`、`TeamDeleteTool`、`SendMessageTool` 使用 lazy require（`() => require(...)`）打破循环依赖链。

6. **Delta Attachments**：工具列表、MCP 指令、agent 列表使用 delta 机制——只发送与之前状态相比新增的部分，减少 token 消耗。

---

## 二、ADK Python (Google Agent Development Kit)

### 1. 项目概述

ADK Python 是 Google 的 Agent Development Kit，一个用于构建 AI Agent 应用的 Python 框架。核心代码位于 `src/google/adk/`，包含 agents、flows、tools、events、sessions、models、memory 等子模块。

**技术栈**：Python 3.10+、asyncio、Pydantic、google.genai

**核心源码文件**：
- `src/google/adk/runners.py`（~2000+ 行）：Runner 核心，编排 Agent 执行
- `src/google/adk/flows/llm_flows/base_llm_flow.py`（~60.6KB）：LLM 流程核心
- `src/google/adk/flows/llm_flows/functions.py`（~1297 行）：函数调用处理
- `src/google/adk/flows/llm_flows/compaction.py`：上下文压缩
- `src/google/adk/agents/base_agent.py`：Agent 基类
- `src/google/adk/tools/base_tool.py`：Tool 基类
- `src/google/adk/tools/tool_context.py`：工具上下文

### 2. 架构概览

ADK Python 采用**分层架构**，每层有明确职责：

```
┌──────────────────────────────────────────────┐
│                  Runner                       │
│  ┌─────────────────────────────────────────┐ │
│  │         Plugin Manager                   │ │
│  │  (before_run, on_event, after_run)       │ │
│  ├─────────────────────────────────────────┤ │
│  │    Node Runner / Dynamic Scheduler       │ │
│  │  ┌─────────────────────────────────┐    │ │
│  │  │        BaseAgent / Workflow       │    │ │
│  │  │  ┌──────────────────────────┐    │    │ │
│  │  │  │     BaseLlmFlow           │    │    │ │
│  │  │  │  preprocess → LLM →       │    │    │ │
│  │  │  │  postprocess → func calls  │    │    │ │
│  │  │  └──────────────────────────┘    │    │ │
│  │  └─────────────────────────────────┘    │ │
│  ├─────────────────────────────────────────┤ │
│  │  Session Service │ Memory Service │      │ │
│  │  Artifact Service │ Credential Service   │ │
│  └─────────────────────────────────────────┘ │
├──────────────────────────────────────────────┤
│              Event Queue (asyncio.Queue)      │
└──────────────────────────────────────────────┘
```

**核心设计模式**：
- **Invocation Context**：每次调用创建独立的上下文，包含 session、agent、 invocation_id 等
- **Event Queue**：Agent 产生的事件通过 `asyncio.Queue` 传递，Runner 消费并持久化
- **Plugin System**：before_run、on_event、after_run 回调链
- **Node Runtime**：统一的节点运行时，支持 BaseAgent 和 Workflow 节点

### 3. Agent Loop 机制

Agent Loop 的核心在 `base_llm_flow.py` 的 `runAsync` 方法中：

```python
async def runAsync(self, invocation_context):
    while True:
        # 1. 预处理：运行 request processors
        # 2. 调用 LLM API
        # 3. 后处理：运行 response processors
        # 4. 处理函数调用
        # 5. 如果没有函数调用或达到终止条件，退出循环
```

**循环流程**：
1. **Preprocess**：运行 `requestProcessors` 管道（包括 compaction 检查）
2. **Call LLM**：通过 model service 调用 LLM，获取流式响应
3. **Postprocess**：运行 `responseProcessors` 管道
4. **Handle Function Calls**：
   - 为每个 function call 生成 client function call ID
   - 执行权限检查和认证
   - 执行工具（同步工具在 ThreadPoolExecutor 中运行）
   - 收集 function responses
   - 处理 agent transfer
5. 如果有 function calls，回到步骤 1；否则返回最终事件

**Request/Response Processors 管道**：
- `CompactionRequestProcessor`：检查 token 阈值，触发上下文压缩
- 其他自定义 processor：认证、限流、日志等

**Runner 层面的执行流程**（`runners.py`）：

`run_async` 方法支持三种入口：
1. **LlmAgent（chat mode）**：通过 `_run_node_async` 走 Node Runner 路径
2. **BaseNode（非 Agent）**：直接通过 Node Runner 执行
3. **传统 Agent**：通过 `_exec_with_plugin` 走 plugin 包裹的执行路径

**Node Runner 执行**：
```python
async def _run_node_async(self, ...):
    # 1. 获取或创建 session
    # 2. 验证并解析 resume inputs
    # 3. 创建 InvocationContext
    # 4. 运行 plugin on_user_message callback
    # 5. 追加用户消息到 session
    # 6. 运行 plugin before_run callback
    # 7. 启动 root node 在后台任务中
    # 8. 主循环：消费 event queue，持久化，yield
    # 9. 清理：取消未完成的任务，运行 after_run callback
    # 10. 运行 event compaction（如果启用）
```

### 4. Tool System

**BaseTool 抽象类**（`src/google/adk/tools/base_tool.py`）：

```python
class BaseTool(ABC):
    name: str
    description: str
    is_long_running: bool = False      # 长运行操作标记
    _defers_response: bool = False    # 延迟响应（内部使用）
    custom_metadata: Optional[dict]   # 自定义元数据

    def _get_declaration(self) -> FunctionDeclaration:
        """返回 OpenAPI 规范的函数声明"""

    async def run_async(self, *, args, tool_context) -> Any:
        """执行工具"""

    async def process_llm_request(self, *, tool_context, llm_request) -> None:
        """处理 outgoing LLM 请求，最常见用途是添加函数声明"""
```

**ToolContext**：简单别名 `ToolContext = Context`，提供对 session state、memory、artifacts 的访问。

**函数调用处理**（`src/google/adk/flows/llm_flows/functions.py`）：

关键函数：
- `generate_client_function_call_id()`：生成 `adk-` 前缀的唯一 ID
- `populate_client_function_call_id(event)`：为缺失 ID 的 function call 填充 ID
- `remove_client_function_call_id(content)`：发送到后端前移除客户端 ID
- `_call_tool_in_thread_pool(tool, args, tool_context)`：在线程池中执行同步工具
- `_is_sync_tool(tool)`：检测工具是否为同步（非 async）

**同步 vs 异步工具**：
- 异步工具：直接 `await tool.run_async(args=args, tool_context=ctx)`
- 同步工具：通过 `ThreadPoolExecutor` 在独立线程中执行，避免阻塞事件循环

**Tool Confirmation**：工具可以请求用户确认（`requestedToolConfirmations`），系统生成 `adk_request_confirmation` 函数调用事件。

**Auth Handling**：工具可以请求认证配置（`requestedAuthConfigs`），系统生成 `adk_request_credential` 函数调用事件。

### 5. Context Management

**Session 模型**：
- Session 包含 events 列表，每个 event 有 author、content、actions、invocation_id
- `EventActions` 包含 state_delta、artifact_delta、transfer_to_agent、escalate 等

**Compaction**（`src/google/adk/flows/llm_flows/compaction.py`）：

`CompactionRequestProcessor` 是一个 request processor，在每次 LLM 调用前检查 token 阈值：

```python
class CompactionRequestProcessor:
    async def process(self, invocation_context, llm_request):
        # 检查 token 使用量是否超过阈值
        # 如果超过，调用 _run_compaction_for_token_threshold_config
        # 压缩 session events
```

**Event Compaction**（App 级别）：
Runner 在每次 invocation 完成后检查是否需要 event compaction：
```python
if self.app and self.app.events_compaction_config:
    await _run_compaction_for_sliding_window(
        self.app, session, self.session_service,
        skip_token_compaction=ic.token_compaction_checked,
    )
```

**Sliding Window 策略**：保持最近 N 个事件的窗口，压缩更早的事件。

### 6. Streaming

ADK Python 通过 `AsyncGenerator` 模式实现流式输出：

```python
async def run_async(self, ...) -> AsyncGenerator[Event, None]:
    async with aclosing(self._run_node_async(...)) as agen:
        async for event in agen:
            yield event
```

**Event 消费**（`_consume_event_queue`）：
```python
async def _consume_event_queue(self, ic, done_sentinel):
    while True:
        event_or_done, processed_signal = await ic._event_queue.get()
        if event_or_done is done_sentinel:
            break
        event = event_or_done
        # 运行 plugin on_event callback
        # 持久化到 session
        yield event
        # 通知生产者事件已处理
```

**Live Mode**：支持 WebSocket 双向通信，包括音频流、转录事件。Live mode 中的事件处理更复杂：
- 部分转录事件（`partial=True`）不持久化
- 函数调用事件在转录完成前缓冲
- 媒体事件（inline data）不持久化，但 file data 引用持久化

### 7. Memory

ADK Python 提供 `BaseMemoryService` 抽象，支持跨 session 的记忆：

- **Memory Service**：可选注入到 Runner 中
- **Session State**：通过 `state_delta` 在事件中记录状态变更
- **Artifacts**：通过 `BaseArtifactService` 管理二进制文件

**Session State 管理**：
- 每个事件的 `EventActions.state_delta` 记录状态变更
- `session.state` 是所有 state_delta 的累积
- 支持 `app:` 前缀（应用级状态）和 `user:` 前缀（用户级状态）

**Rewind 机制**：
`rewind_async` 支持回退到指定 invocation 之前的状态：
1. 计算反向 state_delta（恢复到回退点的状态）
2. 计算反向 artifact_delta（恢复 artifact 版本）
3. 创建 rewind event 记录回退操作

### 8. Orchestration

**Agent 层次结构**：
- `BaseAgent` 支持 `sub_agents` 列表
- `parent_agent` 引用形成树结构
- `find_agent(name)` 在树中查找 agent
- `find_sub_agent(name)` 查找直接子 agent

**Agent Transfer**：
- 工具可以通过 `EventActions.transfer_to_agent` 触发 agent 切换
- `_find_agent_to_run` 根据会话历史找到应该运行的 agent
- `_is_transferable_across_agent_tree` 检查 agent 是否可以跨树转移

**Task Isolation Scope**：
- 支持 task-mode 子 agent，通过 `isolation_scope` 隔离
- Function call delegation：scope = `fc.id`
- Workflow node：scope = `<node_name>@<run_id>`
- `_find_active_task_isolation_scope`：反向扫描 session events 找到活跃的暂停 task

**Dynamic Node Scheduler**：
对于有子 agent 的 agent，使用 `DynamicNodeScheduler` 调度子节点执行，支持 workflow 图的动态调度。

**Resumability**：
- `ResumabilityConfig` 配置是否支持恢复
- 通过 `invocation_id` 恢复中断的调用
- Function response 消息可以恢复之前的 invocation
- `_resolve_invocation_id_from_fr` 通过匹配 function response 到 function call 来推断 invocation_id

### 9. Policy / Governance

**Plugin System**：
- `BasePlugin` 定义 before_run、on_event、after_run、on_user_message 回调
- `PluginManager` 管理插件生命周期和回调链
- 插件可以修改事件（返回替换事件）
- 插件可以提前终止执行（before_run 返回 Content）

**Tool Confirmation**：
- 工具可以通过 `requestedToolConfirmations` 请求用户确认
- 系统生成 `adk_request_confirmation` 函数调用
- 用户确认后恢复执行

**Auth Management**：
- 工具可以通过 `requestedAuthConfigs` 请求认证
- `BaseCredentialService` 管理认证凭据
- 系统生成 `adk_request_credential` 函数调用
- 认证完成后恢复执行

**Long-Running Operations**：
- `is_long_running` 标记长运行工具
- `event.long_running_tool_ids` 记录长运行调用
- 影响 A2A 转换、plugin 日志、中断跟踪

### 10. 关键技术决策

1. **ToolContext = Context 别名**：简化工具开发，工具直接访问 session state、memory 等，无需额外抽象层。

2. **Event Queue 解耦**：Agent 执行与事件持久化通过 `asyncio.Queue` 解耦，允许异步并行执行和流式输出。

3. **双路径执行**：Runner 支持传统 Agent 路径（`_exec_with_plugin`）和 Node Runtime 路径（`_run_node_async`），逐步迁移到统一 Node Runtime。

4. **Sync Tool Thread Pool**：同步工具在 `ThreadPoolExecutor` 中执行，避免阻塞 asyncio 事件循环，同时保持对同步工具的兼容。

5. **Session Events 作为 Source of Truth**：所有状态变更（state_delta、artifact_delta）记录在事件中，session state 是事件重放的结果，支持 rewind。

6. **Compaction 双层架构**：Token-level compaction（`CompactionRequestProcessor`）在 LLM 调用前检查；Event-level compaction（App 配置）在 invocation 结束后执行 sliding window 压缩。

---

## 三、ADK Dart

### 1. 项目概述

ADK Dart 是 Google Agent Development Kit 的 Dart 实现，结构与 Python 版高度对齐。它是为 Flutter 应用设计的 Agent 框架，支持 Live Mode（WebSocket 双向通信）。

**技术栈**：Dart 3+、async/await、Flutter

**核心源码文件**：
- `lib/src/runners/runner.dart`：Runner 编排 Agent 执行
- `lib/src/flows/llm_flows/base_llm_flow.dart`（~1479 行）：LLM 流程协调器
- `lib/src/flows/llm_flows/functions.dart`：函数调用处理
- `lib/src/agents/llm_agent.dart`：LLM Agent 实现

### 2. 架构概览

ADK Dart 的架构与 Python 版高度对齐，但利用了 Dart 的语言特性：

```
┌──────────────────────────────────────────────┐
│                  Runner                       │
│  ┌─────────────────────────────────────────┐ │
│  │         Plugin Manager                   │ │
│  ├─────────────────────────────────────────┤ │
│  │         Node Runner                      │ │
│  │  ┌─────────────────────────────────┐    │ │
│  │  │      BaseLlmFlow (Dart)          │    │ │
│  │  │  runAsync → _runOneStepAsync      │    │ │
│  │  │  preprocess → LLM → postprocess   │    │ │
│  │  │  → handle function calls          │    │ │
│  │  └─────────────────────────────────┘    │ │
│  ├─────────────────────────────────────────┤ │
│  │  Session Service │ Memory Service │      │ │
│  │  Artifact Service │ Credential Service   │ │
│  └─────────────────────────────────────────┘ │
├──────────────────────────────────────────────┤
│           Event Queue (StreamController)      │
└──────────────────────────────────────────────┘
```

### 3. Agent Loop 机制

`base_llm_flow.dart`（~1479 行）实现了核心 Agent Loop：

**`runAsync` 方法**：
```dart
Future<void> runAsync(InvocationContext invocationContext) async {
  while (true) {
    final shouldContinue = await _runOneStepAsync(invocationContext);
    if (!shouldContinue) break;
  }
}
```

**`_runOneStepAsync` 方法**（单步执行）：
1. **Preprocess**：运行 `requestProcessors` 管道
2. **Call LLM**：`_callLlmAsync` 调用 LLM API
3. **Postprocess**：运行 `responseProcessors` 管道
4. **Handle Function Calls**：`_postprocessHandleFunctionCallsAsync`

**`_postprocessHandleFunctionCallsAsync`**：
- 处理函数调用响应
- 执行 auth 检查（`generateAuthEvent`）
- 执行 tool confirmation（`generateRequestConfirmationEvent`）
- 处理 agent transfer
- 执行工具函数
- 生成 function response 事件

**Live Mode 支持**：
`base_llm_flow.dart` 包含对 Live Mode 的深度支持：
- WebSocket 连接管理
- 自动重连机制
- Session resumption（通过 `resumption` 参数）
- 实时音频流处理

### 4. Tool System

**`functions.dart`** 实现了与 Python 版对齐的函数调用处理：

```dart
// 生成客户端函数调用 ID
String generateClientFunctionCallId() {
  return newAdkId(prefix: afFunctionCallIdPrefix);
}

// 填充缺失的 ID
void populateClientFunctionCallId(Event modelResponseEvent) {
  for (final FunctionCall call in modelResponseEvent.getFunctionCalls()) {
    call.id ??= generateClientFunctionCallId();
  }
}

// 移除客户端 ID（发送到后端前）
void removeClientFunctionCallId(Content? content) {
  for (final Part part in content.parts) {
    if (part.functionCall?.id?.startsWith(afFunctionCallIdPrefix) == true) {
      part.functionCall!.id = null;
    }
  }
}
```

**Long-Running Tool 跟踪**：
```dart
Set<String> getLongRunningFunctionCalls(
  List<FunctionCall> functionCalls,
  Map<String, BaseTool> toolsDict,
) {
  final Set<String> ids = {};
  for (final FunctionCall call in functionCalls) {
    final BaseTool? tool = toolsDict[call.name];
    if (tool != null && tool.isLongRunning && call.id != null) {
      ids.add(call.id!);
    }
  }
  return ids;
}
```

**Auth 事件生成**：
`generateAuthEvent` 从工具的 `requestedAuthConfigs` 构建认证请求事件，生成 `adk_request_credential` 函数调用。

**Tool Confirmation 事件生成**：
`generateRequestConfirmationEvent` 从工具的 `requestedToolConfirmations` 构建确认请求事件。

### 5. Context Management

ADK Dart 的上下文管理与 Python 版对齐：

**Session**：包含 events 列表，每个 event 有 author、content、actions、invocationId
**EventActions**：包含 stateDelta、artifactDelta、transferToAgent、escalate、requestedAuthConfigs、requestedToolConfirmations、compaction、endOfAgent、agentState 等

**Compaction**：
- App 级别配置：`events_compaction_config`
- Sliding window 策略
- Token 阈值检查
- 在 invocation 完成后执行压缩

**`_isEmptyEventActions`** 检查：
```dart
bool _isEmptyEventActions(EventActions actions) {
  return actions.skipSummarization == null &&
      actions.stateDelta.isEmpty &&
      actions.artifactDelta.isEmpty &&
      actions.transferToAgent == null &&
      actions.escalate == null &&
      actions.requestedAuthConfigs.isEmpty &&
      actions.requestedToolConfirmations.isEmpty &&
      actions.compaction == null &&
      actions.endOfAgent == null &&
      actions.agentState == null &&
      actions.rewindBeforeInvocationId == null &&
      actions.renderUiWidgets.isEmpty;
}
```

### 6. Streaming

ADK Dart 通过 Dart 的 `Stream` 和 `async generator` 模式实现流式输出：

```dart
Stream<Event> runAsync({...}) async* {
  await for (final event in _runNodeAsync(...)) {
    yield event;
  }
}
```

**Event Queue**：使用 `StreamController` 或类似的异步队列机制传递事件。

**Live Mode Streaming**：
- 支持 WebSocket 双向通信
- 音频流实时处理
- 转录事件流（partial 和 non-partial）
- 函数调用事件缓冲（等待转录完成后释放）

### 7. Memory

ADK Dart 的记忆系统与 Python 版对齐：

- **Memory Service**：可选注入到 Runner
- **Session State**：通过 `stateDelta` 在事件中记录
- **Artifacts**：通过 `BaseArtifactService` 管理

### 8. Orchestration

ADK Dart 的编排能力与 Python 版对齐：

**Agent 层次结构**：`BaseAgent` 支持 `subAgents` 列表，形成树结构
**Agent Transfer**：通过 `transferToAgent` action 触发
**Workflow**：支持 `Workflow` 类型的 root agent，内部处理路由
**Node Runner**：统一的节点运行时

**Runner 执行流程**（`runner.dart`）：
```dart
Future<void> _runNodeAsync({...}) async {
  // 1. 获取或创建 session
  // 2. 验证并解析 resume inputs
  // 3. 创建 InvocationContext
  // 4. 运行 plugin on_user_message callback
  // 5. 追加用户消息到 session
  // 6. 运行 plugin before_run callback
  // 7. 启动 root node 在后台
  // 8. 主循环：消费 event queue，持久化，yield
  // 9. 清理
  // 10. 运行 event compaction
}
```

### 9. Policy / Governance

与 Python 版对齐：

- **Plugin System**：before_run、on_event、after_run 回调
- **Tool Confirmation**：`adk_request_confirmation` 机制
- **Auth Management**：`adk_request_credential` 机制
- **Long-Running Operations**：`isLongRunning` 标记

### 10. 关键技术决策

1. **与 Python 版高度对齐**：Dart 版几乎 1:1 复制了 Python 版的架构和 API，降低跨平台学习成本，便于双语言维护。

2. **Live Mode 深度集成**：Dart 版在 `base_llm_flow.dart` 中直接集成了 WebSocket 连接管理、自动重连、session resumption，适合 Flutter 实时应用场景。

3. **Dart 语言特性利用**：
   - `async*` 生成器函数实现流式输出
   - `Stream` 和 `StreamController` 替代 Python 的 `AsyncGenerator`
   - null safety 语言特性减少运行时错误

4. **Event Actions 统一模型**：`EventActions` 包含所有可能的动作（stateDelta、artifactDelta、transferToAgent、escalate、requestedAuthConfigs、requestedToolConfirmations、compaction、endOfAgent、agentState、rewindBeforeInvocationId、renderUiWidgets），一个结构覆盖所有场景。

5. **SessionNotFoundError 显式错误**：不使用 auto-create session 作为默认行为，强制用户明确处理 session 不存在的情况，减少意外行为。

---

## 四、三项目对比分析

| 维度 | claude-code | ADK Python | ADK Dart |
|------|-------------|------------|----------|
| **语言** | TypeScript (Bun) | Python 3.10+ | Dart 3+ |
| **运行时** | Bun | CPython | Dart VM |
| **UI 层** | React + Ink (终端) | 无内置 UI | Flutter |
| **Agent Loop** | query.ts (~1730行) | base_llm_flow.py | base_llm_flow.dart (~1479行) |
| **Tool Schema** | Zod | Pydantic / FunctionDeclaration | Dart 类型系统 |
| **Tool Exec** | 直接 async | ThreadPool for sync | 直接 async |
| **Compaction** | 全量+部分，forked agent | Token 阈值+Sliding window | 同 Python |
| **Memory** | CLAUDE.md 文件 | BaseMemoryService | 同 Python |
| **Orchestration** | Coordinator 模式 | Agent Transfer + Workflow | 同 Python |
| **Streaming** | Async Generator | AsyncGenerator | Stream + async* |
| **Permission** | 4种模式 + deny rules | Plugin 回调 | 同 Python |
| **Live Mode** | 不支持 | 支持（实验性） | 深度集成 |
| **Feature Flags** | bun:bundle 编译时 | 运行时 | 运行时 |

### 关键差异

1. **claude-code 是产品，ADK 是框架**：claude-code 是一个完整的终端应用，有 UI、CLI、权限系统；ADK 是开发框架，提供构建 Agent 应用的基础设施。

2. **Compaction 复杂度**：claude-code 的 compaction 系统远比 ADK 复杂——支持全量/部分压缩、forked agent cache 复用、PTL 重试、文件恢复、skill 恢复、多种 delta 附件重注入。ADK 的 compaction 相对简单，主要是 token 阈值触发的 sliding window。

3. **Tool 安全模型**：claude-code 有细粒度的安全属性（isConcurrencySafe、isReadOnly、isDestructive、shouldDefer）和 fail-closed 默认值；ADK 依赖 plugin 回调和显式的 confirmation/auth 机制。

4. **Coordinator vs Agent Transfer**：claude-code 的 Coordinator 模式是显式的多 agent 协调，coordinator 不执行代码操作，只分发任务；ADK 的 Agent Transfer 是隐式的，通过事件中的 transferToAgent action 实现。

5. **Context Cache**：claude-code 深度优化 prompt cache——工具排序保持 cache 稳定性、forked agent 复用 cache prefix、delta attachments 减少 token 消耗；ADK 没有类似级别的 cache 优化。

6. **Live Mode**：ADK Dart 对 Live Mode（WebSocket 实时通信）有深度支持，包括音频流、转录事件、自动重连；claude-code 不支持 Live Mode。

---

## 五、对白泽项目的启示

基于以上分析，对白泽 iOS 编程智能体的架构设计有以下启示：

1. **Agent Loop 设计**：采用 claude-code 的 streaming + tool loop 模式，但参考 ADK 的 processor 管道设计，使 compaction、auth 等横切关注点可插拔。

2. **Tool System**：采用 claude-code 的 `buildTool` 工厂模式 + fail-closed 安全默认值，但使用 Swift 的类型系统替代 Zod。

3. **Context Management**：借鉴 claude-code 的精细 compaction 策略（全量+部分），但简化实现——iOS 场景对话长度通常较短。

4. **Memory**：采用 claude-code 的文件式记忆系统（类似 CLAUDE.md），结合 iOS 的 App Group 文件共享。

5. **Orchestration**：如果需要多 agent 协调，采用 claude-code 的 Coordinator 模式而非 ADK 的 Agent Transfer，更符合编程场景。

6. **Permission System**：采用 claude-code 的多模式权限系统（default/plan/auto），结合 iOS 的沙盒权限模型。
