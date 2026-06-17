# Agent 框架源码深度分析报告

> 本报告基于对 crewAI、LangGraph、Maestro、Mastra、DSPy 五个 Agent 框架的**核心源码**深度阅读，覆盖10个分析维度，并针对 iOS 本地编程 Agent 的技术可行性给出启示。

---

## 1. Maestro

### 1.1 项目概述

Maestro 是一个基于 LangGraph 的多 Agent 计划→执行→审查编排器，使用 Node.js/ESM 编写。核心依赖：`@langchain/langgraph`、`@modelcontextprotocol/sdk`、`liquidjs` 模板引擎，支持 SQLite/PostgreSQL 持久化。

**核心设计哲学**：将软件开发工作流建模为有限状态机（FSM），每个角色（planner/executor/reviewer）对应 FSM 中的一个节点，通过状态转移表驱动任务流转。

### 1.2 架构概述

```
CLI/HTTP → Orchestrator → StateMachine → LangGraph Graph
                ↓                           ↓
          WorkflowStore              AgentRunner (Terminal/Herdr)
                ↓                           ↓
          TaskStore (JSON/SQLite/PG)    Provider Adapters (claude/codex/ollama/gemini)
                ↓
          MCP Server (8 tools)
```

核心模块：
- `orchestrator.mjs`：tick-based 调度循环，运行时状态管理（running/claimed/retrying/completed maps）
- `state-machine.mjs`：FSM 定义，包含 sink states 和转移表
- `workflow.mjs`：YAML front-matter 工作流定义，支持热重载
- `agent-runner.mjs`：CLI 进程沙箱化执行
- `langgraph/engine.mjs`：桥接 legacy JSON store 与 LangGraph StateGraph
- `langgraph/graph.mjs`：从 workflow.json 构建 LangGraph 图
- `langgraph/nodes.mjs`：每个角色创建 LangGraph 节点函数
- `router.mjs`：角色→Provider 路由策略

### 1.3 Agent 定义与编排

Maestro 的 Agent 不是传统意义上的自主智能体，而是**角色（Role）**——在 FSM 中承担特定职责的节点：

- **Planner**：任务分解与计划生成，使用 claude 作为默认 Provider
- **Executor**：代码实现与执行，使用 codex 作为默认 Provider
- **Reviewer**：代码审查与质量评估，使用 codex 作为默认 Provider

角色间通过 **Handoff 机制**通信，使用紧凑的标记格式：
- `MAESTRO_HANDOFF`：角色间任务交接
- `MAESTRO_QUESTION`：向用户提问
- `MAESTRO_REVIEW`：审查结果反馈
- `MAESTRO_ACTION_REQUEST`：请求用户操作

`src/markers.mjs` 中定义了输出标记解析器，支持上下文窗口失败检测（匹配 "context window"、"too many tokens" 等模式）和用量限制失败检测（匹配 "rate limit"、"429"、"quota" 等模式）。

### 1.4 Workflow/状态机

Maestro 的状态机是核心设计：

**Sink States（汇合状态）**：
- `$complete`：任务完成
- `$halt`：任务终止
- `$ask_user`：等待用户输入
- `$pause`：暂停
- `$wait`：等待条件满足

**Reserved Events（保留事件）**：`done`、`error`、`question`、`waiting`、`needs_review`、`pause`

**转移函数** `transition(currentState, event)`：从当前状态 + 事件查转移表，决定下一状态。

**循环控制**：
- `resolveMaxVisits()`：per-role 和 workflow 级别的循环限制
- `effectiveSkipForState()`：skip 控制（"auto" | "always" | "never"）
- `isTerminalAfterState()`：基于模式的终止判断

### 1.5 Tool 集成

Maestro 通过 **MCP (Model Context Protocol)** 暴露工具：

`src/mcp/server.mjs` 定义了 8 个 MCP 工具：
- `list_tasks`、`show_task`、`list_runs`、`show_run`：任务和运行查询
- `create_task`、`get_state`：任务创建和状态查询
- `read_workflow`、`validate_workflow`：工作流管理

安全措施：`assertInsideDir()` 防路径遍历、`isValidId()` 防注入、敏感配置脱敏。

**Provider 适配器注册表**（`src/adapters/registry.mjs`）：
- 内置适配器：claude、codex、copilot、gemini、antigravity、ollama
- 自定义适配器：支持模板令牌 `{alias}`、`{model}`、`{effort}`、`{permission}`、`{role}`

### 1.6 Memory

Maestro **没有内置 Memory 系统**。状态管理依赖：
- LangGraph 的 `MemorySaver` checkpointer（进程内，非跨进程）
- `MaestroState` Annotation：`task`、`priorHandoffs`（role-deduplicating reducer）、`visits`（incrementing reducer）、`event`、`currentState`
- 外部持久化：SQLite/PostgreSQL 通过 `tryOpenStore()` 或 legacy JSON 文件

### 1.7 编排模式

**Plan→Execute→Review 模式**：
1. Planner 规划任务
2. Executor 执行实现
3. Reviewer 审查结果
4. 循环直到完成或达到循环限制

**审查状态机**（`_applyReviewerOutcome()`）：
- `complete`：通过审查
- `incomplete_continueable`：需要继续
- `incomplete_needs_user`：需要用户输入
- `incomplete_needs_approval`：需要批准
- `blocked_external`/`blocked_repo_state`/`blocked_safety`：各类阻塞
- `failed_agent`/`uncertain`：异常状态

**Planner 策略**：auto/on/off 模式，auto 模式通过模式匹配判断复杂度来决定是否需要规划。

### 1.8 错误处理与重试

- **指数退避重试**：`computeRetryDelay` 支持延续
- **失速检测**：`last_event_at_ms` + 可配置 `stallTimeoutMs`
- **上下文窗口重试**：自动压缩输出并重试，`handoffMode = "strict"`
- **用量限制重试**：切换到备用 Provider（最多 `USAGE_RETRY_LIMIT=2` 次）
- **循环限制恢复**：当 `loop_limit_exceeded` 阻塞器存在时，驱逐循环角色
- **Git HEAD 守护**：检测非审查角色的未授权提交

### 1.9 可扩展性

- **Provider 适配器**：注册表模式支持新增 LLM 后端
- **工作流定义**：YAML front-matter + Liquid 模板，支持热重载
- **MCP 工具**：可扩展的工具协议
- **自定义事件透传**：handoff 可能路由声明的转移

### 1.10 对 iOS 本地 Agent 的启示

| 模式 | 启示 |
|------|------|
| FSM + Sink States | iOS 本地 Agent 应采用显式 FSM 而非隐式状态，sink state 设计（完成/暂停/等待用户）非常适合移动端中断场景 |
| Handoff 标记 | 角色间通信使用紧凑标记格式，token 效率高，适合本地设备有限上下文窗口 |
| Provider 适配器 | iOS 应设计 LLM Provider 抽象层，支持本地模型（Core ML/On-Device）和云端模型切换 |
| 失速检测 + 循环限制 | 本地 Agent 必须有超时和循环限制，防止无限消耗设备资源 |
| MCP 协议 | 工具协议标准化，iOS 可借鉴 MCP 的工具发现和调用模式 |

---

## 2. LangGraph

### 2.1 项目概述

LangGraph 是用于构建有状态多参与者应用的 Python 框架。核心概念：**StateGraph**（状态图）、**Channels**（通道/状态通道）、**Pregel** 执行引擎、**Checkpointing**（检查点）。

### 2.2 架构概述

```
StateGraph → Node/Edge Registration → Pregel Engine → Super-step Execution
                    ↓                        ↓
              Channel System           Checkpoint Saver
         (LastValue/BinOp/Delta/Ephemeral)     ↓
                                      MemorySaver / SqliteSaver / PostgresSaver
```

核心文件：
- `graph/state.py`：StateGraph 类，基于 Annotation 的状态定义
- `pregel/main.py`：Pregel 执行引擎
- `graph/_node.py`：StateNode 类型定义
- `channels/`：各种通道类型实现

### 2.3 Agent 定义与编排

LangGraph 不定义 Agent 概念，而是将每个**节点函数**视为一个执行单元：

```python
# StateNode Protocol 变体
- StateNode: (state: State) -> dict
- StateNodeWithConfig: (state: State, config: RunnableConfig) -> dict
- StateNodeWithWriter: (state: State, *, writer: StreamWriter) -> dict
- StateNodeWithStore: (state: State, *, store: BaseStore) -> dict
```

`StateNodeSpec` dataclass 包含：`runnable`、`metadata`、`input_schema`、`retry_policy`、`cache_policy`、`timeout`、`error_handler`

节点注册与边连接：
```python
graph = StateGraph(State)
graph.add_node("node_name", node_function)
graph.add_edge("node_a", "node_b")
graph.add_conditional_edges("node", router_function)
```

### 2.4 Workflow/状态机

LangGraph 的核心抽象是**通道（Channel）系统**：

**BaseChannel**（`channels/base.py`）：抽象基类，定义 `get()`、`update()`、`checkpoint()`、`from_checkpoint()` 接口。

**LastValue**（`channels/last_value.py`）：
- 每步只能接收一个值，多值并发更新抛 `InvalidUpdateError`
- 适合表示"当前状态"的单一值字段

**LastValueAfterFinish**：
- 只有在 `finish()` 后才可用，消费后清除
- 适合跨 step 的信号传递

**BinaryOperatorAggregate**（`channels/binop.py`）：
- 使用二元操作符聚合值（如 `operator.add` 累加列表）
- 支持 `Overwrite` 类型覆盖当前值
- 适合需要累积的状态（如消息列表）

**Delta**：增量更新通道
**EphemeralValue**：临时值，不持久化到检查点

StateGraph 的状态定义使用 **Annotation** 模式：
```python
class State(TypedDict):
    messages: Annotated[list, add_messages]  # BinaryOperatorAggregate with list concatenation
    count: int                                # LastValue
```

### 2.5 Tool 集成

LangGraph 本身不定义 Tool 系统，但通过 LangChain 生态集成：
- ToolNode：预构建节点，执行工具调用
- Tool 调用通过状态中的消息列表传递
- 支持并行工具执行

### 2.6 Memory

LangGraph 的 Memory 体系：

- **Checkpointing**：每步执行后保存完整状态快照
  - `MemorySaver`：内存存储（进程内）
  - `SqliteSaver`：SQLite 持久化
  - `PostgresSaver`：PostgreSQL 持久化
- **状态通道**：不同通道类型实现不同的状态语义
- **Store**：键值存储，用于跨图共享数据

### 2.7 编排模式

- **线性图**：节点间固定边连接
- **条件分支**：`add_conditional_edges` 根据函数返回值路由
- **循环**：节点可以连接回前驱节点
- **并行分支**：多个节点可以从同一节点出发
- **子图**：图嵌套，支持组合复杂流程

### 2.8 错误处理与重试

- **RetryPolicy**：节点级重试策略，可配置最大重试次数和退避
- **CachePolicy**：节点级缓存，避免重复计算
- **timeout**：节点级超时
- **error_handler**：节点级错误处理器

### 2.9 可扩展性

- **自定义通道类型**：继承 BaseChannel 实现自定义状态语义
- **自定义检查点存储**：继承 BaseCheckpointSaver
- **子图组合**：图可嵌套组合
- **流式处理**：支持流式输出和中间结果

### 2.10 对 iOS 本地 Agent 的启示

| 模式 | 启示 |
|------|------|
| Channel 系统 | iOS 本地 Agent 的状态管理应采用类型化的通道语义：单值覆盖（LastValue）、列表累积（BinOp）、临时信号（Ephemeral），而非统一字典 |
| Checkpointing | 每步状态快照对本地 Agent 至关重要——移动端随时可能被中断，需要可靠恢复 |
| Pregel 超步模型 | 超步执行模型（所有节点同步更新）比自由异步更适合受限设备上的确定性执行 |
| 条件边 | 条件路由比硬编码流程更灵活，iOS Agent 可根据设备状态/网络条件动态路由 |
| 自定义通道 | iOS 可定义专用通道类型：如 BatteryAwareChannel、MemoryWarningChannel |

---

## 3. crewAI

### 3.1 项目概述

crewAI 是 Python 多 Agent 框架，采用 **Crew → Agent → Task** 模型。Monorepo 结构包含：crewai（核心）、crewai-core（内部核心）、crewai-tools（工具集）、crewai-files（文件处理）。支持顺序和层级流程、A2A 协议、MCP 集成、知识/RAG、Memory、Skills、Guardrails、Checkpoints。

### 3.2 架构概述

```
Crew (FlowTrackable + BaseModel)
  ├── agents: list[Agent]          ─── Agent (BaseAgent)
  │                                    ├── role, goal, backstory, llm, tools, knowledge
  │                                    ├── max_iter, max_rpm, knowledge
  │                                    └── AgentExecutor / CrewAgentExecutor
  ├── tasks: list[Task]            ─── Task (BaseModel)
  │                                    ├── description, expected_output, agent
  │                                    ├── context, tools, guardrails
  │                                    └── output_json, output_pydantic, output_file
  ├── process: Process             ─── sequential | hierarchical
  ├── memory: Memory               ─── UnifiedMemory (LLM分析 + 向量存储)
  └── flow: Flow                   ─── Flow DSL (@start/@listen/@router)
```

### 3.3 Agent 定义与编排

**Agent** 类（`agent/core.py`）关键属性：
- `role`、`goal`、`backstory`：Agent 身份定义
- `llm`：使用的语言模型
- `tools`：可用工具列表
- `knowledge`：知识检索配置
- `max_iter`：最大迭代次数
- `max_rpm`：速率限制
- `knowledge`/`skills`/`guardrails`/`checkpoints`：高级功能
- `mcp`：MCP 集成
- 双执行器支持：`CrewAgentExecutor`（已废弃）和 `AgentExecutor`（新）

**Crew 编排模式**（`process.py`）：
- `sequential`：按任务列表顺序执行
- `hierarchical`：层级式，Manager Agent 分配任务

### 3.4 Workflow/状态机

crewAI 的 Flow 系统（`flow/`）是独立于 Crew 的编排层：

**Flow DSL**（`flow/dsl.py`）：
- `@start`：标记流程入口方法
- `@listen`：监听事件触发
- `@router`：条件路由
- `or_()`/`and_()`：事件组合

**FlowDefinition**（`flow/flow_definition.py`）：可序列化的 Flow 契约
- `FlowActionDefinition`：code（Python 函数）/ tool（CrewAI 工具）/ expression（CEL 表达式）
- `FlowMethodDefinition`：方法定义（do/start/listen/router/emit/human_feedback/persist）
- `FlowConfigDefinition`：tracing/stream/memory/max_method_calls/checkpoint
- 支持 JSON/YAML 序列化和反序列化

**Flow Runtime**（`flow/runtime.py`）：执行引擎和状态管理

### 3.5 Tool 集成

- **BaseTool**：工具基类
- **Tool 在 Agent 和 Task 两级配置**：Agent 级别定义默认工具，Task 级别可覆盖
- **MCP 集成**：Agent 支持 MCP 工具发现
- **A2A 协议**：Agent-to-Agent 通信
- **input_files**：文件输入支持

### 3.6 Memory

crewAI 的 Memory 系统是其最完善的部分之一：

**Unified Memory**（`memory/unified_memory.py`）：
- 独立于 Agent/Crew，可独立使用
- LLM 分析推断 scope、categories、importance
- 支持浅层（shallow）和深层（deep）recall

**MemoryRecord**（`memory/types.py`）：
- `id`、`content`、`scope`（分层路径如 `/company/team/user`）
- `categories`、`metadata`、`importance`（0-1）
- `created_at`、`last_accessed`、`embedding`
- `source`（来源追踪）、`private`（隐私过滤）

**复合评分**：
```
composite = semantic_weight * similarity + recency_weight * decay + importance_weight * importance
```
其中 `decay = 0.5^(age_days / half_life_days)`

默认权重：semantic=0.5, recency=0.3, importance=0.2

**MemoryScope**：范围视图，限定根路径
**MemorySlice**：多范围视图，跨 scope 搜索

**存储后端**：
- LanceDB（默认）：向量搜索
- Qdrant Edge：边缘部署向量数据库
- 自定义后端：通过 `resolve_memory_storage` 扩展

**EncodingFlow**：LLM 驱动的编码流程
**RecallFlow**：自适应深度回忆流程，支持 confidence-based 路由

**关键特性**：
- 后台保存：`remember_many()` 非阻塞，通过 ThreadPoolExecutor
- 读屏障：`recall()` 自动等待未完成的写入
- 整合：相似度 > consolidation_threshold 时触发合并/更新/删除
- 隐私：`private` 标记，仅同 source 可见

### 3.7 编排模式

- **Sequential Process**：任务按顺序执行
- **Hierarchical Process**：Manager Agent 分配任务
- **Flow 编排**：基于事件的 DAG
- **Guardrails**：任务输出验证，支持函数和 LLM 驱动的 guardrail
- **Human Feedback**：人工审查机制

### 3.8 错误处理与重试

- **Guardrail 重试**：`guardrail_max_retries`（默认3），每次重试重新执行 Agent
- **Guardrail 类型**：callable 函数或 LLM-based（`LLMGuardrail`）
- **多 Guardrail**：`guardrails` 列表，按顺序验证
- **异步支持**：`_ainvoke_guardrail_function` 异步版本
- **事件总线**：`crewai_event_bus` 发布 TaskStarted/TaskCompleted/TaskFailed 事件

### 3.9 可扩展性

- **自定义 Memory 后端**：`StorageBackend` 抽象
- **自定义 Embedder**：`build_embedder` 工厂
- **自定义 Flow Action**：code/tool/expression 三种类型
- **Flow 序列化**：JSON/YAML 导出导入
- **Checkpoint**：Crew 和 Task 级别的检查点

### 3.10 对 iOS 本地 Agent 的启示

| 模式 | 启示 |
|------|------|
| 统一 Memory + LLM 分析 | iOS 本地 Agent 的 Memory 应集成 LLM 分析自动推断 scope/importance/categories，而非依赖手动标注 |
| 复合评分（semantic+recency+importance）| 本地 Memory 检索应综合语义相似度、时间衰减、重要性，而非仅向量搜索 |
| Scope 层级路径 | iOS Agent 应采用分层 scope（如 `/app/session/task`）组织 Memory，支持隔离和继承 |
| 后台保存 + 读屏障 | Memory 写入应异步非阻塞，但读取时必须有读屏障确保一致性 |
| Guardrail 机制 | 任务输出验证是必要的，iOS Agent 的工具调用结果应经过验证才可提交 |
| Flow DSL | 事件驱动的 Flow 编排比固定顺序更灵活，适合复杂的本地工作流 |

---

## 4. DSPy

### 4.1 项目概述

DSPy 是用于**编程基础模型**的 Python 框架。与其它框架不同，DSPy 关注的不是 Agent 编排，而是**声明式编程**：通过 Signature 定义输入输出约束，通过 Module 组合管道，通过 Teleprompter（优化器）自动优化 prompt 和 few-shot 示例。

### 4.2 架构概述

```
Signature (input/output contract)
    ↓
Module (Predict/ChainOfThought/ReAct/...)
    ↓ forward()
Adapter (ChatAdapter) → LM (BaseLM) → Completion
    ↓
Teleprompter (Bootstrap/MIPRO/Simba/GEPA/...)
    ↓ compile()
Optimized Module (with demos + refined instructions)
```

### 4.3 Agent 定义与编排

DSPy 的核心抽象不是 Agent，而是 **Module**（`primitives/module.py`）：

```python
class Module(BaseModule, metaclass=ProgramMeta):
    def __init__(self, callbacks=None):
        self.callbacks = callbacks or []
        self._compiled = False
        self.history = []
    
    def __call__(self, *args, **kwargs) -> Prediction:
        # 使用 settings.context 管理 caller_modules
        # 支持 usage tracking
        return self.forward(*args, **kwargs)
    
    async def acall(self, *args, **kwargs) -> Prediction:
        return await self.aforward(*args, **kwargs)
```

**Module 特性**：
- `ProgramMeta` 元类确保所有实例正确初始化
- `named_predictors()`：递归查找所有 Predict 子模块
- `set_lm()`/`get_lm()`：统一管理语言模型
- `batch()`：并行处理多个 Example
- `dump_state()`/`load_state()`：序列化/反序列化

### 4.4 Workflow/状态机

DSPy **没有显式的状态机或工作流**。流程通过 Python 代码组合：

```python
class MyProgram(dspy.Module):
    def __init__(self):
        self.predictor = dspy.Predict("question -> answer")
    
    def forward(self, question):
        return self.predictor(question=question)
```

流程 = Python 代码执行路径，灵活性最高但需要手动管理。

### 4.5 Signature 系统

**Signature**（`signatures/signature.py`）是 DSPy 最核心的创新：

```python
class MySignature(dspy.Signature):
    question: str = InputField(desc="...")
    answer: int = OutputField(desc="...")
```

或字符串格式：
```python
sig = dspy.Signature("question, context -> answer")
```

**SignatureMeta** 元类：
- 自动推断 instructions（如未提供，默认 "Given the fields X, produce the fields Y"）
- 验证所有字段使用 `InputField` 或 `OutputField`
- 自动推断 prefix（属性名→可读标题）
- 支持类型注解解析（通过 AST 解析字符串格式中的类型）

**Signature 操作**：
- `with_instructions(instructions)`：创建新 instructions 的副本
- `prepend(name, field)` / `append(name, field)` / `insert(index, name, field)`：添加字段
- `delete(name)`：删除字段
- `with_updated_fields(name, type_, **kwargs)`：更新字段
- `dump_state()` / `load_state()`：序列化状态（instructions + prefix + desc）

### 4.6 Tool 集成

DSPy **没有内置 Tool 系统**。但提供了：
- **ReAct** 模块：实现推理-行动循环
- **Code Interpreter**：代码执行
- **Python Interpreter**：Python 代码执行沙箱

### 4.7 Memory

DSPy **没有内置 Memory**。状态管理通过：
- **Example**（`primitives/example.py`）：键值对数据结构，支持 `inputs()` 过滤输入字段
- **Prediction**（`primitives/prediction.py`）：继承 Example，添加 `completions` 和 `lm_usage`
- **History**：Module 级别的调用历史

### 4.8 编排模式

- **Predict**：最基本的模块，Signature → LM → Prediction
- **ChainOfThought**：添加 "Reasoning: Let's think step by step" 中间输出
- **ReAct**：推理-行动循环
- **ProgramOfThought**：生成代码执行
- **Module 组合**：Module 可嵌套组合

**Predict.forward()** 核心流程：
1. `_forward_preprocess()`：提取 signature、demos、config、LM
2. 温度处理：多生成时自动设 temperature=0.7
3. 输入验证：类型检查、缺失字段警告
4. Adapter 调用：`adapter(lm, lm_kwargs, signature, demos, inputs)`
5. `_forward_postprocess()`：构建 Prediction，记录 trace

### 4.9 错误处理与重试

DSPy 的错误处理较简单：
- 输入类型验证和警告
- LM 配置验证（必须是 BaseLM 实例）
- 状态加载时的安全过滤（`_sanitize_lm_state`）

**Teleprompter 优化**：通过编译过程隐式处理错误——失败示例会被排除在 demo 之外。

### 4.10 可扩展性

- **自定义 Signature**：字段类型、描述、instructions 完全可定制
- **自定义 Module**：继承 Module 实现 forward()
- **自定义 Adapter**：控制 LM 调用格式
- **Teleprompter 扩展**：继承 Teleprompter 实现 compile()

**Teleprompter 生态**：
- `BootstrapFewShot`：基于成功轨迹的 few-shot 优化
- `MIPROv2`：多指令提议优化
- `Simba`：基于模拟退火的优化
- `GEPA`：引导进化提示优化
- `COPRO`：对比提示优化
- `BootstrapFinetune`：微调优化
- `GRPO`：强化学习优化
- `Ensemble`：集成优化

### 4.11 对 iOS 本地 Agent 的启示

| 模式 | 启示 |
|------|------|
| Signature 声明式契约 | iOS 本地 Agent 的每个步骤应有明确的输入输出 Schema，而非自由文本 |
| Module 组合 | Agent 管道应通过模块组合构建，而非硬编码流程 |
| Teleprompter 自动优化 | iOS 端可考虑本地优化 prompt 的机制，根据用户反馈自动调整 |
| 类型安全的 Signature | Signature 的 AST 类型解析确保类型安全，iOS/Swift 天然强类型，应充分利用 |
| ProgramMeta 元类 | 自动初始化保证对 iOS Agent 有价值——防止子类遗漏初始化 |

---

## 5. Mastra

### 5.1 项目概述

Mastra 是 TypeScript AI Agent 框架，采用 monorepo 结构（packages/core 为主包）。支持 Agent、Workflow、Tool、Memory、MCP 等完整功能。特色是 Durable Agent（持久化 Agent）和 Evented Workflow（事件驱动工作流）。

### 5.2 架构概述

```
Mastra (Registry)
  ├── Agent (Base)                 ─── 基础 Agent
  ├── DurableAgent                 ─── 持久化 Agent (Workflow-backed)
  ├── Workflow                     ─── Step-based Workflow
  │     ├── DefaultEngine
  │     └── EventedEngine
  ├── Tools                        ─── Zod Schema + Execute
  ├── Memory (MastraMemory)        ─── Thread-based Memory
  ├── LLM (MastraLLM)             ─── Multi-provider LLM
  └── MCP                          ─── MCP 集成
```

### 5.3 Agent 定义与编排

**Agent**（`agent/agent.ts`）是一个大型类（约1500行），核心特性：

- **多模型支持**：`MastraLLMV1`（传统）和 `MastraLLMVNext`（新版循环）+ `ModelRouterLanguageModel`（路由）
- **Tool 集成**：MastraTool、ProviderTool、WorkspaceTool、SkillTool
- **Memory**：`MastraMemory` 接口，支持 thread-based 对话
- **Processor 管道**：输入/输出/错误处理器（支持工作流式处理）
- **网络循环**：`networkLoop()` 实现多 Agent 协作
- **Goal 系统**：`GoalSignalProvider`、`Objective`、`Scorer` — 目标驱动的执行
- **Channel 系统**：`AgentChannels` 实现多 Agent 间通信
- **通知系统**：`createNotificationSignal()` / `resolveNotificationDeliveryDecision()`
- **权限系统**：`MastraFGAPermissions`（细粒度权限）
- **代理委托**：`SubAgent` 支持 Agent 间委托调用

**DurableAgent**（`agent/durable/durable-agent.ts`）：
- 包装基础 Agent，提供持久化执行能力
- 基于 Workflow 的 Durable Agentic Workflow
- 支持挂起（suspend）和恢复（resume）
- 支持工具审批（requireToolApproval）
- 支持后台任务（background tasks）
- 缓存支持：`InMemoryServerCache` 或自定义（如 Redis）

### 5.4 Workflow/状态机

Mastra 的 Workflow 系统分为两种引擎：

**Default Engine**（`workflows/default.ts`）：
- 基于 Step 的线性/分支执行
- 支持 `suspend`/`resume`
- 支持 `mapVariable` 在步骤间传递变量

**Evented Engine**（`workflows/evented/`）：
- 事件驱动的工作流执行
- `WorkflowEventProcessor`：loop、parallel、dispatch、retry-budget
- `StepExecutor`：步骤执行器
- `ExecutionEngine`：执行引擎

**Step**（`workflows/step.ts`）核心接口：
```typescript
ExecuteFunctionParams {
  runId, resourceId, workflowId, mastra,
  requestContext, actor, inputData, state,
  setState(), resumeData?, suspendData?, retryCount,
  getInitData(), getStepResult(),
  suspend(), bail(), abort(),
  resume?, restart?,
  writer, outputWriter?
}
```

**Workflow 特性**：
- `suspend()`：挂起工作流，等待外部恢复
- `bail()`：提前退出当前步骤
- `abort()`：中止工作流
- `mapVariable`：步骤间变量映射
- 条件函数：`ConditionFunction` 控制流转
- 调度器：Cron 定时触发
- 状态读取：`StateReader`

### 5.5 Tool 集成

**Tool 系统**（`tools/`）：

- **createTool()**：Zod Schema + Execute 函数
- **ToolBuilder**：流式 Builder 模式
- **Code Mode**（`tools/code-mode/`）：代码执行工具，支持沙箱
- **Workspace Tools**（`workspace/tools/`）：完整的文件系统工具集
  - `read-file`、`write-file`、`edit-file`、`delete-file`
  - `list-files`、`file-stat`、`mkdir`
  - `execute-command`、`grep`、`search`
  - `ast-edit`：AST 级代码编辑
  - `get-process-output`、`kill-process`
  - `lsp-inspect`
- **Payload Transform**：工具负载转换策略
- **Tool Hooks**：beforeExecute/afterExecute
- **Tool Approval**：`requireToolApproval` 支持工具调用审批
- **Provider Tools**：AI SDK Provider 工具适配
- **Background Tasks**：工具后台执行

### 5.6 Memory

- **MastraMemory**（`memory/`）：接口定义
- **Working Memory**：`isWorkingMemoryToolName()` 工具
- **Thread-based**：基于 thread 的对话持久化
- **Memory Config**：`MemoryConfig`/`MemoryConfigInternal`
- **Save Queue**：`SaveQueueManager` 异步保存

### 5.7 编排模式

- **单 Agent 循环**：Agent 内部 tool-use 循环
- **Network Loop**：`networkLoop()` 多 Agent 协作
- **Workflow Step**：Step-based DAG
- **Durable Workflow**：可挂起/恢复的持久化工作流
- **Goal-driven**：目标驱动的执行循环
- **Channel 通信**：Agent 间通过 Channel 通信

### 5.8 错误处理与重试

- **Step retryCount**：步骤级重试计数
- **Retry Budget**（Evented Engine）：重试预算管理
- **Error Processor**：错误处理管道
- **TripWire**：`agent/trip-wire.ts` 触发条件检测
- **Durable 恢复**：suspend/resume 机制天然支持错误恢复
- **Background Task Check**：后台任务状态检查步骤

### 5.9 可扩展性

- **Tool 扩展**：createTool() + Zod Schema
- **Processor 扩展**：输入/输出/错误处理器管道
- **Storage 扩展**：自定义存储后端
- **LLM 扩展**：Provider 适配器
- **Workspace 扩展**：自定义工作空间工具
- **Skill 扩展**：`SkillFormat` 技能系统

### 5.10 对 iOS 本地 Agent 的启示

| 模式 | 启示 |
|------|------|
| Durable Agent + Workflow | iOS 本地 Agent 必须是 Durable 的——随时可被系统中断、内存警告杀死，需要可靠的 suspend/resume |
| Goal-driven 执行 | 目标驱动的执行循环（Objective + Scorer）比固定步骤更适合不确定性的本地编程任务 |
| Workspace Tools 全集 | iOS 编程 Agent 需要完整的文件系统工具集（读写编辑搜索），Mastra 的实现是好的参考 |
| AST Edit | AST 级别的代码编辑比文本替换更可靠，iOS 编程 Agent 应采用结构化编辑 |
| Tool Approval | 工具调用审批机制对本地 Agent 至关重要——危险操作需用户确认 |
| Channel 通信 | 多 Agent 间通过 Channel 通信比直接调用更解耦，适合 iOS 的多组件协作 |
| Background Tasks | 本地 Agent 的长时任务应支持后台执行和状态检查 |

---

## 跨框架对比总结

### 核心架构模式对比

| 维度 | Maestro | LangGraph | crewAI | DSPy | Mastra |
|------|---------|-----------|--------|------|--------|
| 语言 | Node.js | Python | Python | Python | TypeScript |
| Agent 模型 | Role (FSM Node) | Node Function | Agent+Task | Module+Signature | Agent+Durable |
| 编排方式 | FSM 转移表 | 图+边+条件边 | Crew Process/Flow | Python 代码组合 | Workflow Steps |
| 状态管理 | MaestroState+LangGraph | Channel System | Flow State | Python State | Workflow State |
| Memory | 无（依赖外部） | Checkpoint | Unified Memory (LLM+Vector) | Example/Prediction | MastraMemory |
| Tool 集成 | MCP | LangChain Tools | BaseTool+MCP+A2A | ReAct (无内置) | createTool+Workspace |
| 错误处理 | 指数退避+失速检测+循环限制 | RetryPolicy+timeout | Guardrail 重试 | 基础验证 | RetryBudget+TripWire |
| 持久化 | SQLite/PG | Checkpoint Store | Checkpoint | dump/load_state | Durable Workflow |

### iOS 本地编程 Agent 关键启示

1. **状态机驱动**：Maestro 的 FSM + LangGraph 的 Channel 系统启示，本地 Agent 应采用显式状态机而非隐式状态管理。Sink state 设计（完成/暂停/等待用户）完美适配移动端中断场景。

2. **持久化执行**：Mastra 的 Durable Agent + Workflow 是移动端必备特性。Agent 必须能被随时 suspend/resume，状态需要可靠持久化到本地存储。

3. **复合 Memory 评分**：crewAI 的 semantic+recency+importance 复合评分优于纯向量搜索。本地 Memory 应综合多维度，且支持 scope 层级隔离。

4. **声明式 I/O 契约**：DSPy 的 Signature 系统启示，每个 Agent 步骤应有明确的类型化输入输出定义，而非自由文本。Swift 强类型系统天然适配此模式。

5. **工具审批机制**：Mastra 的 Tool Approval 对本地安全至关重要。文件系统修改、网络请求等危险操作需用户确认。

6. **Provider 适配**：Maestro 的适配器注册表启示，iOS 应设计统一的 LLM Provider 抽象，支持本地模型（Core ML）和云端模型切换，并在用量限制时自动降级。

7. **循环限制 + 失速检测**：本地 Agent 必须有执行时间/迭代次数限制，防止无限循环消耗设备资源。

8. **AST 级代码编辑**：Mastra 的 AST Edit 工具启示，编程 Agent 应采用结构化代码编辑而非文本替换，确保代码语法正确性。

9. **紧凑 Handoff 协议**：Maestro 的标记格式 Handoff 在有限上下文窗口下效率更高，适合本地模型。

10. **事件驱动编排**：crewAI 的 Flow DSL 和 Mastra 的 Evented Engine 启示，事件驱动的编排比固定流程更灵活，适合复杂且不确定的本地编程工作流。
