# Memory / Skill / Planning 源码深度分析报告

> 分析对象：mem0, langmem, skillkit, openskills, goalweaver, saber, orra, shipit_agent, ms-agent  
> 分析维度：(1) 项目概览与核心功能 (2) 架构概览与模块 (3) Memory System (4) Skill System (5) Planning/Goal System (6) iOS 本地 Agent 移植启示

---

## 一、mem0

### 1. 项目概览与核心功能

mem0 是一个生产级的多层记忆管理库，为 AI Agent 提供持久化、可检索的记忆层。核心功能包括：

- **多范围记忆**：支持 `user_id`、`agent_id`、`run_id` 三维实体隔离，实现会话级/用户级/Agent 级记忆分区
- **多类型记忆**：`MemoryType` 枚举覆盖事实记忆（默认）和过程记忆（PROCEDURAL）
- **多后端向量存储**：20+ 向量数据库后端（FAISS、Chroma、Qdrant、Pinecone、PGVector 等）
- **多嵌入模型**：OpenAI、Ollama、HuggingFace、FastEmbed、Gemini 等
- **BM25 + 向量混合检索**：`score_and_rank` / `normalize_bm25` 实现关键词+语义双重排序
- **实体提取与过滤**：自动从消息中提取实体用于记忆分区

### 2. 架构概览与模块

```
mem0/
├── memory/
│   ├── base.py          # MemoryBase 抽象基类 (CRUD 接口)
│   ├── main.py          # Memory 主类 (核心逻辑)
│   └── telemetry.py     # 遥测
├── embeddings/          # EmbedderFactory + 各后端实现
├── llm/                 # LlmFactory + 各 LLM 后端
├── vector_stores/       # VectorStoreFactory + 20+ 后端
├── reranker/            # RerankerFactory + 各排序器
├── utils/               # BM25、实体提取、过滤构建
└── config/              # 配置模型
```

**核心设计模式**：
- **Factory 模式**：`EmbedderFactory`、`LlmFactory`、`RerankerFactory`、`VectorStoreFactory` 实现依赖注入，通过配置字符串动态创建实例
- **Abstract Base Class**：`MemoryBase` 定义 `get`/`get_all`/`add`/`update`/`delete`/`search`/`history` 统一接口
- **Filter Builder**：`_build_filters_and_metadata()` 将 user_id/agent_id/run_id 转换为向量存储过滤条件

### 3. Memory System 实现

**记忆添加流程**（`Memory.add()`）：
1. 实体验证：检查 user_id/agent_id/run_id 合法性
2. 敏感字段脱敏：自动移除 password/token/secret 等字段
3. LLM 提取：使用 `ADDITIVE_EXTRACTION_PROMPT` 从输入中提取事实性记忆条目
4. 向量化：通过 Embedder 将记忆文本转为嵌入向量
5. 向量存储写入：连同元数据（user_id, agent_id, run_id, hash）写入向量数据库
6. 事件历史记录：每次操作记录到 history

**记忆搜索流程**：
1. 构建过滤条件（基于 user_id/agent_id/run_id）
2. 向量相似度搜索 + BM25 关键词搜索
3. 结果合并与重排序（可选 Reranker）
4. 返回带分数的记忆列表

**过程记忆**（PROCEDURAL）：
- 使用专门的 `PROCEDURAL_MEMORY_SYSTEM_PROMPT` 提取"如何做"类型的知识
- 独立于事实记忆存储，支持独立检索

**关键接口**（`MemoryBase`）：
```python
class MemoryBase(ABC):
    def get(self, memory_id): ...
    def get_all(self): ...
    def update(self, memory_id, data): ...
    def delete(self, memory_id): ...
    def history(self, memory_id): ...
    @abstractmethod
    def add(self, data, user_id=None, agent_id=None, run_id=None, metadata=None, filters=None): ...
    @abstractmethod
    def search(self, query, user_id=None, agent_id=None, run_id=None, limit=100, filters=None): ...
```

### 4. Skill System 实现

mem0 不涉及 Skill System。

### 5. Planning/Goal System 实现

mem0 不涉及 Planning/Goal System。

### 6. iOS 本地 Agent 移植启示

- **向量存储选择**：iOS 端可使用 FAISS（C++ 库，可编译为 iOS framework）或 SQLite + vec 扩展作为本地向量存储
- **嵌入模型选择**：可使用 FastEmbed（ONNX Runtime 后端）在设备端运行嵌入模型，或使用 Ollama 本地模型
- **实体过滤机制**：`_build_filters_and_metadata()` 的 user_id/agent_id/run_id 三维过滤设计可直接移植到 iOS 端
- **BM25 混合检索**：纯 Python 实现的 BM25 可移植为 Swift 版本，与向量检索结合提升召回率
- **Factory 模式**：依赖注入设计便于在 iOS 端替换后端实现（如 Core ML 替代 OpenAI embeddings）
- **敏感数据脱敏**：内置的敏感字段过滤逻辑应保留在 iOS 端实现
- **过程记忆**：PROCEDURAL 类型的记忆提取对 iOS 本地 Agent 特别有价值——可记录用户操作习惯和偏好

---

## 二、langmem

### 1. 项目概览与核心功能

langmem 是 LangChain/LangGraph 生态的记忆管理库，核心功能包括：

- **短期记忆**：基于 token 预算的对话摘要（`SummarizationNode`），自动在超出 token 限制时触发摘要
- **长期记忆**：通过 `trustcall` 库从对话中提取知识条目，存储到 LangGraph 的 `BaseStore`
- **反射机制**：`ReflectionExecutor` 对记忆进行反思和精炼
- **提示优化**：`create_prompt_optimizer` / `create_multi_prompt_optimizer` 基于记忆自动优化 Agent 提示

### 2. 架构概览与模块

```
langmem/
├── __init__.py              # 公共 API 导出
├── short_term/
│   └── summarization.py     # SummarizationNode + RunningSummary
├── knowledge/
│   └── extraction.py        # 知识提取（trustcall 集成）
├── reflection/
│   └── executor.py          # ReflectionExecutor
└── optimization/
    └── prompt_optimizer.py   # 提示优化器
```

**核心设计模式**：
- **LangGraph Node 模式**：`SummarizationNode` 作为 LangGraph 图节点，可无缝插入任何 LangGraph 工作流
- **Token Budget 模式**：`max_tokens_before_summary` / `max_tokens` / `max_summary_tokens` 三级 token 控制
- **Running Summary 模式**：增量摘要而非全量重算，保留已摘要消息 ID 避免重复处理

### 3. Memory System 实现

**短期记忆**（`summarization.py`，~860 行完整分析）：

核心数据结构：
```python
class RunningSummary:
    summary: str                           # 当前摘要文本
    summarized_message_ids: list[str]      # 已摘要的消息 ID 列表
    last_summarized_message_id: str | None # 最后一条已摘要消息 ID
```

摘要流程（`summarize_messages()`）：
1. 计算当前消息的 token 总数
2. 若未超出 `max_tokens_before_summary`，直接返回所有消息
3. 若超出，将旧消息（含 RunningSummary）传入 LLM 生成新摘要
4. 返回 `SummarizationResult`，包含保留的近期消息和新的 RunningSummary

**SummarizationNode**：
- LangGraph 兼容节点，接收消息列表，自动触发摘要
- 支持 `max_tokens_before_summary`（触发阈值）与 `max_tokens`（输出上限）分离
- 异步支持：`asummarize_messages()`

**长期记忆**（`extraction.py`，部分分析）：
- `Item` / `SearchItem` 继承 LangGraph 的 `BaseItem` / `BaseSearchItem`
- 使用 `trustcall` 库进行结构化知识提取
- 与 LangGraph 的 `BaseStore` 深度集成

**反射与优化**：
- `ReflectionExecutor`：对提取的记忆进行反思，去除冗余/错误
- `create_prompt_optimizer`：基于记忆内容自动调整 Agent 系统提示
- `create_multi_prompt_optimizer`：多提示并行优化

### 4. Skill System 实现

langmem 不涉及 Skill System。

### 5. Planning/Goal System 实现

langmem 不涉及 Planning/Goal System。

### 6. iOS 本地 Agent 移植启示

- **Token Budget 模式**：iOS 端应实现类似的三级 token 控制（触发阈值/输出上限/摘要上限），对有限的设备内存至关重要
- **Running Summary 增量摘要**：避免全量重算，适合 iOS 端低功耗场景
- **摘要触发策略**：`max_tokens_before_summary` 的延迟触发设计可在 iOS 端减少不必要的 LLM 调用
- **知识提取**：`trustcall` 的结构化提取模式可参考，但需替换为 iOS 端可用的 LLM 接口
- **提示优化**：基于记忆自动调整系统提示的机制在 iOS 端特别有价值——可适应用户使用习惯变化
- **LangGraph 解耦**：`SummarizationNode` 虽然依赖 LangGraph，但其核心逻辑（token 计数 + 增量摘要）可独立提取为纯 Swift 实现

---

## 三、skillkit

### 1. 项目概览与核心功能

skillkit 是一个 Python Skill 管理框架，为 AI Agent 提供技能的发现、解析、缓存、内容处理和脚本执行能力。核心功能：

- **渐进式披露**：`SkillMetadata`（轻量元数据）→ `Skill`（完整内容，懒加载）
- **多源技能发现**：文件系统扫描（SKILL.md）、插件清单（MCPB v0.3）
- **YAML 前置元数据解析**：含拼写纠错、安全校验
- **内容处理管线**：基础目录注入 + 参数替换（`$ARGUMENTS` 占位符）
- **脚本执行引擎**：支持 Python/Shell/JS/Ruby/Perl，含完整安全控制
- **MCPB 插件规范**：v0.3 插件清单解析与验证
- **优先级冲突解决**：PROJECT(100) > ANTHROPIC(50) > PLUGIN(10) > CUSTOM(5)

### 2. 架构概览与模块

```
skillkit/
├── core/
│   ├── models.py      # 数据模型 (SkillMetadata, Skill, ContentCache, PluginManifest 等)
│   ├── discovery.py   # 文件系统技能发现 (SkillDiscovery)
│   ├── parser.py      # YAML 前置元数据解析 (SkillParser)
│   ├── manager.py     # 中心注册表 (SkillManager)
│   ├── processors.py  # 内容处理管线 (ContentProcessor 策略模式)
│   └── scripts.py     # 脚本检测与执行 (ScriptDetector, ScriptExecutor)
```

**核心设计模式**：
- **Progressive Disclosure**：`SkillMetadata` 冻结数据类（仅元数据）→ `Skill` 冻结数据类（含 `@cached_property content`）
- **Strategy Pattern**：`ContentProcessor` ABC → `BaseDirectoryProcessor` + `ArgumentSubstitutionProcessor` → `CompositeProcessor` 组合
- **Factory + Registry**：`SkillManager` 统一注册、发现、调用
- **LRU Cache + mtime 失效**：`ContentCache` 基于 `asyncio.Lock` 的线程安全缓存

### 3. Memory System 实现

skillkit 不涉及 Memory System。

### 4. Skill System 实现

**技能发现**（`discovery.py`，434 行完整分析）：

- `SkillDiscovery` 文件系统扫描器，递归搜索 SKILL.md 文件
- `find_skill_files(skills_dir, max_depth=5)`：递归遍历，深度限制 5 层
- 循环符号链接检测：基于 inode 的 visited 集合
- 大小写不敏感匹配：SKILL.md / skill.md / Skill.md 均识别
- 插件清单发现：`discover_plugin_manifest()` 解析 `.claude-plugin/plugin.json`
- 异步版本：`adiscover_skills` / `ascan_directory` / `afind_skill_files`

**技能解析**（`parser.py`，444 行完整分析）：

- `SkillParser` 提取 YAML 前置元数据（regex: `---\n...---` 模式）
- `TYPO_MAP` 拼写纠错映射：`allowed_tools→allowed-tools` 等
- `parse_skill_file(skill_path) → SkillMetadata`
- `parse_plugin_manifest()`：JSON 炸弹保护（1MB 限制），路径遍历/盘符安全检查

**技能模型**（`models.py`，713 行完整分析）：

```python
@frozen
class SkillMetadata:
    name: str
    description: str
    skill_path: str
    allowed_tools: list[str]
    version: str | None

@frozen
class Skill:
    metadata: SkillMetadata
    
    @cached_property
    def content(self) -> str: ...  # 懒加载技能内容
    
    def invoke(self, arguments: dict | None = None) -> str: ...
    async def ainvoke(self, arguments: dict | None = None) -> str: ...
```

- `SourceType` 枚举：PROJECT(100) > ANTHROPIC(50) > PLUGIN(10) > CUSTOM(5)
- `QualifiedSkillName`：支持 `plugin:skill` 格式的全限定名，`parse()` 工厂方法
- `PluginManifest`：MCPB v0.3 规范，含安全验证（路径遍历、盘符检测）
- `ContentCache`：LRU 缓存 + mtime 失效 + `asyncio.Lock` 线程安全

**内容处理**（`processors.py`，407 行完整分析）：

- `normalize_arguments()`：参数规范化用于缓存键生成
- `ContentProcessor` ABC + Strategy 模式
- `BaseDirectoryProcessor`：注入基础目录上下文（`$BASE_DIR` 变量）
- `ArgumentSubstitutionProcessor`：`string.Template` 安全替换 `$ARGUMENTS`
  - 可疑模式检测：9 种危险模式（`__import__`, `eval(`, `exec(`, `subprocess` 等）
  - 拼写检测：`$ARGUMENT` → `$ARGUMENTS` 纠错
- `CompositeProcessor`：链式组合多个处理器

**脚本执行**（`scripts.py`，1239 行完整分析）：

- `INTERPRETER_MAP`：`.py→python3`, `.sh→bash`, `.js→node`, `.rb→ruby`, `.pl→perl`
- `ScriptMetadata`：含 `get_fully_qualified_name()` 生成 LangChain 工具 ID（`skill__script`）
- `ScriptDescriptionExtractor`：从 Python docstring、`#` 注释、JS 注释提取描述
- `ScriptDetector`：递归扫描，排除符号链接，跳过缓存目录
- `ScriptExecutor` 安全控制：
  - `_validate_script_path()`：路径遍历防护（`../` 检测）
  - `_check_permissions()`：setuid/setgid 拒绝
  - `_resolve_interpreter()`：解释器路径解析
  - `_execute_subprocess()`：`shell=False` 安全执行
  - 超时强制终止
  - 输出截断（10MB 限制）
  - 审计日志记录

### 5. Planning/Goal System 实现

skillkit 不涉及 Planning/Goal System。

### 6. iOS 本地 Agent 移植启示

- **渐进式披露**：iOS 端应采用 SkillMetadata（轻量）→ Skill（按需加载内容）的两阶段设计，减少内存占用
- **YAML 前置元数据**：可简化为更轻量的 JSON 或 TOML 格式，便于 iOS 端解析
- **安全控制**：脚本执行的安全检查（路径遍历、setuid 拒绝、超时、输出截断）必须全部保留——iOS 端的安全边界更为严格
- **内容缓存**：mtime 失效 + LRU 缓存策略适合 iOS 端文件系统特性
- **参数替换**：`$ARGUMENTS` 占位符模式可直接移植，但需替换 `string.Template` 为 Swift 原生字符串处理
- **插件架构**：MCPB v0.3 插件规范可参考设计 iOS 端的插件系统，但需适配 App Sandbox 限制
- **脚本执行替代**：iOS 端无法执行 Python/Shell/JS 脚本，需替换为 Swift 函数闭包或 URL Scheme 调用
- **优先级冲突解决**：多源技能的优先级机制在 iOS 端同样重要，特别是系统预设技能 vs 用户自定义技能

---

## 四、openskills

### 1. 项目概览与核心功能

openskills 是一个 TypeScript/Node.js CLI 工具，用于通用技能管理。核心功能：

- **技能列表**：列出项目级和全局级已安装技能
- **技能安装**：从 GitHub 仓库或 Git URL 安装技能文件
- **技能阅读**：查看技能内容
- **技能移除**：删除已安装技能
- **技能同步**：将已安装技能信息写入 AGENTS.md
- **技能管理**：查看技能元数据和位置信息

### 2. 架构概览与模块

```
openskills/
├── src/
│   ├── cli.ts       # CLI 入口 (list/install/read/remove/manage/sync)
│   ├── types.ts     # 类型定义 (Skill, SkillMetadata, SkillLocation, InstallOptions)
│   ├── skills.ts    # 技能操作逻辑
│   └── utils.ts     # 工具函数
```

**核心类型**：
```typescript
interface Skill {
  name: string;
  description: string;
  location: 'project' | 'global';
  path: string;
}

interface SkillLocation {
  path: string;
  baseDir: string;
  source: string;
}

interface InstallOptions {
  global?: boolean;
  universal?: boolean;
  yes?: boolean;
}
```

### 3. Memory System 实现

openskills 不涉及 Memory System。

### 4. Skill System 实现

**技能生命周期管理**：

- **安装**：从 GitHub/Git URL 克隆技能文件到本地（支持 `--global` 全局安装、`--universal` 通用安装）
- **发现**：扫描项目目录和全局目录中的 SKILL.md 文件
- **同步**：将已安装技能信息写入 AGENTS.md，使 AI Agent 自动感知可用技能
- **位置管理**：区分项目级（`.skills/`）和全局级（`~/.skills/`）技能

**与 skillkit 的对比**：
| 维度 | skillkit | openskills |
|------|----------|------------|
| 语言 | Python | TypeScript |
| 定位 | 运行时框架 | CLI 工具 |
| 执行能力 | 脚本执行引擎 | 无执行能力 |
| 插件系统 | MCPB v0.3 | 无 |
| 缓存 | LRU + mtime | 无 |
| 安全控制 | 完整 | 基础 |

### 5. Planning/Goal System 实现

openskills 不涉及 Planning/Goal System。

### 6. iOS 本地 Agent 移植启示

- **技能安装模式**：GitHub/Git URL 安装模式在 iOS 端需替换为 App Bundle 内置 + iCloud Drive 导入
- **AGENTS.md 同步**：将技能信息写入 AGENTS.md 的模式可参考，iOS 端可使用类似的"技能清单文件"让 Agent 自动感知
- **项目级/全局级分离**：iOS 端可映射为"App 级"和"用户级"技能存储
- **轻量 CLI 模式**：openskills 的简单操作模型（list/install/read/remove）适合作为 iOS 端技能管理的基础 API 设计

---

## 五、goalweaver

### 1. 项目概览与核心功能

goalweaver 是一个基于 DAG（有向无环图）的目标分解与编排框架。核心功能：

- **DAG 目标图**：使用 `networkx.DiGraph` 构建目标依赖关系
- **自适应规划**：`AdaptivePlanner` 根据优先级和依赖关系选择下一批目标
- **计划重写**：`rewrite(signal)` 基于信号触发计划调整
- **运行时编排**：`Orchestrator` 协调多个 Agent 并发执行目标
- **状态持久化**：运行时状态保存到 `state.json`

### 2. 架构概览与模块

```
goalweaver/
├── types.py          # 数据模型 (Goal, Priority, GoalStatus, Event, StepResult, PlanRewrite)
├── goal_graph.py     # DAG 目标图 (GoalGraph)
├── planner.py        # 自适应规划器 (AdaptivePlanner)
├── agent.py          # Agent 抽象基类 (BaseAgent, Tool)
├── runtime.py        # 运行时编排器 (Orchestrator)
└── strategies/       # 规划策略
```

**核心设计模式**：
- **DAG + Topological Sort**：`GoalGraph` 使用 `networkx.DiGraph` 表示目标依赖
- **Priority Scheduling**：`AdaptivePlanner.next_batch(k)` 综合优先级、入度、创建时间选择目标
- **Event-Driven Rewrite**：`rewrite(signal)` 基于事件信号动态调整计划
- **Concurrent Batch Execution**：`Orchestrator` 并发执行一批就绪目标

### 3. Memory System 实现

goalweaver 不涉及 Memory System。

### 4. Skill System 实现

goalweaver 不涉及 Skill System。

### 5. Planning/Goal System 实现

**数据模型**（`types.py`，完整分析）：

```python
class Priority(IntEnum):
    LOW = 1
    MEDIUM = 2
    HIGH = 3
    CRITICAL = 4

class GoalStatus(str, Enum):
    PENDING = "PENDING"
    READY = "READY"
    IN_PROGRESS = "IN_PROGRESS"
    BLOCKED = "BLOCKED"
    DONE = "DONE"
    FAILED = "FAILED"

class Goal(BaseModel):
    id: str
    title: str
    description: str
    owner_agent: str | None
    priority: Priority = Priority.MEDIUM
    status: GoalStatus = GoalStatus.PENDING
    dependencies: list[str] = []
    metadata: dict = {}
    created_at: datetime
    updated_at: datetime
```

- `StepResult`：Agent 执行结果（status, output, error）
- `Event`：运行时事件（goal_created, goal_completed, goal_failed, plan_rewrite_requested）
- `PlanRewrite`：计划重写请求（trigger, description, proposed_changes）

**目标图**（`goal_graph.py`，完整分析）：

```python
class GoalGraph:
    def __init__(self):
        self.graph = nx.DiGraph()  # 边方向：dependency → goal
    
    def add_goal(self, goal: Goal): ...
    def add_dependency(self, goal_id: str, depends_on: str): ...
    def set_status(self, goal_id: str, status: GoalStatus): ...
    def mark_in_progress(self, goal_id: str): ...
    def mark_done(self, goal_id: str): ...
    def ready_goals(self) -> list[Goal]:
        """拓扑排序：所有前驱 DONE 的目标"""
    def recompute_readiness(self):
        """幂等地重新计算目标就绪状态"""
```

- 边方向设计：`dependency → goal`（依赖指向目标）
- `ready_goals()`：返回所有前驱节点状态为 DONE 的目标
- `recompute_readiness()`：遍历所有 PENDING 目标，检查前驱是否全部 DONE，更新状态为 READY

**自适应规划器**（`planner.py`，完整分析）：

```python
class AdaptivePlanner:
    def __init__(self, graph: GoalGraph): ...
    
    def next_batch(self, k: int = 3) -> list[Goal]:
        """选择下一批目标：
        1. 从 ready_goals() 中筛选
        2. 按 (priority DESC, in-degree ASC, created_at ASC) 排序
        3. 返回前 k 个
        """
    
    def rewrite(self, signal: PlanRewrite) -> GoalGraph:
        """基于信号重写计划（添加/删除目标，修改依赖）"""
```

- 优先级排序策略：高优先级优先 → 低入度优先（减少阻塞） → 早期创建优先
- 默认批次大小 k=3，平衡并行度和资源占用

**Agent 抽象**（`agent.py`，完整分析）：

```python
class BaseAgent(ABC):
    @abstractmethod
    async def act(self, goal: Goal, context: dict) -> StepResult: ...
    
    @abstractmethod
    async def reflect(self) -> list[Event]: ...
    
    @abstractmethod
    async def propose_subgoals(self, goal: Goal) -> list[Goal]: ...

class Tool(ABC):
    name: str
    description: str
    
    @abstractmethod
    async def __call__(self, **kwargs) -> Any: ...
```

- 三阶段 Agent 生命周期：`act`（执行）→ `reflect`（反思）→ `propose_subgoals`（提议子目标）
- `Tool` ABC 定义统一的工具接口

**运行时编排**（`runtime.py`，完整分析）：

```python
class Orchestrator:
    def __init__(self, graph: GoalGraph, agents: dict[str, BaseAgent]): ...
    
    async def run(self, batch_size: int = 3):
        """主循环：
        1. 重新计算就绪状态
        2. 获取下一批目标
        3. 并发执行（asyncio.gather）
        4. 反思 + 子目标提议
        5. 状态持久化
        6. 空闲循环检测（max 200）
        """
    
    async def _run_goal(self, goal: Goal):
        """单目标执行：
        1. 选择 Agent
        2. act() 执行
        3. 根据结果更新状态
        4. reflect() 反思
        5. propose_subgoals() 提议子目标
        """
```

- 并发执行：`asyncio.gather` 并发执行一批目标
- 空闲检测：连续 200 次无就绪目标则终止，将剩余目标标记为 FAILED
- 状态持久化：每轮迭代后保存到 `state.json`

### 6. iOS 本地 Agent 移植启示

- **DAG 目标图**：`networkx.DiGraph` 的功能可用 Swift 的图算法库实现，或自行实现基于邻接表的 DAG
- **拓扑排序**：`ready_goals()` 的拓扑排序逻辑直接可移植为 Swift 实现
- **优先级调度**：`next_batch(k)` 的排序策略（优先级 → 入度 → 创建时间）非常适合 iOS 端的任务调度
- **计划重写**：基于信号动态调整计划的能力在 iOS 端可映射为用户中断/设备状态变化的响应机制
- **并发执行**：iOS 端可使用 Swift Structured Concurrency（`TaskGroup`）替代 `asyncio.gather`
- **状态持久化**：`state.json` 可替换为 Swift 的 `Codable` + FileManager 持久化
- **空闲检测**：200 次空闲检测阈值可调低，iOS 端应更积极地释放资源
- **子目标提议**：`propose_subgoals()` 允许 Agent 动态分解目标，这对复杂编程任务很有价值

---

## 六、saber

### 1. 项目概览与核心功能

saber 是一个 R 语言的代码智能工具包，为 AI 编程 Agent 提供项目上下文。核心功能：

- **函数调用图**：`fn_graph()` 基于 AST 符号索引生成 SVG 函数调用图
- **爆炸半径分析**：`blast_radius()` 跨项目查找所有调用者（内部 + 下游包）
- **Agent 上下文组装**：`agent_context()` 从 memory/instructions/identity 文件组装 AI Agent 上下文
- **项目简报**：`briefing()` 生成包含 DESCRIPTION 元数据 + 下游依赖 + Git 提交的 Markdown 简报

### 2. 架构概览与模块

```
saber/R/
├── fn_graph.R         # 函数调用图 (fn_graph)
├── blast.R            # 爆炸半径 (blast_radius)
├── agent_context.R    # Agent 上下文组装 (agent_context)
└── briefing.R         # 项目简报 (briefing)
```

### 3. Memory System 实现

saber 通过 `agent_context()` 实现了一种轻量级的"文件即记忆"模式：

**agent_context()**（404 行完整分析）：
- 从多个来源组装 Agent 上下文：memory 文件、instructions 文件、identity 文件
- 按 Agent 类型自动加载/跳过特定文件：
  - **Claude**：跳过 Claude Code 的 MEMORY.md 和 CLAUDE.md
  - **Codex**：跳过 AGENTS.md 和 Codex 记忆
- 记忆来源层次：
  - `agent_context_memory()`：加载 Claude Code 项目的 MEMORY.md
  - `agent_context_codex_memory()`：加载 Codex 记忆（含行预算控制）
  - `agent_context_project()`：根据 consumer 选择 CLAUDE.md 或 AGENTS.md
  - `agent_context_global()`：加载全局指令
  - `agent_context_soul()`：加载 SOUL.md 身份文件

### 4. Skill System 实现

saber 不涉及传统 Skill System，但 `agent_context()` 的"上下文文件自动组装"可视为一种隐式技能发现机制——根据 Agent 类型自动匹配和加载上下文。

### 5. Planning/Goal System 实现

saber 不涉及 Planning/Goal System。

### 6. iOS 本地 Agent 移植启示

- **文件即记忆**：MEMORY.md / CLAUDE.md / SOUL.md 的"文件即记忆"模式非常适合 iOS 端——无需数据库，直接使用文件系统
- **Agent 类型感知**：根据不同 Agent 类型自动调整上下文加载策略，iOS 端可映射为不同的"工作模式"（代码编辑/调试/重构）
- **SOUL.md 身份文件**：定义 Agent 个性/身份的机制可移植到 iOS 端，作为用户自定义 Agent 人格的入口
- **爆炸半径分析**：`blast_radius()` 的跨项目调用者分析思路可应用于 iOS 端的代码变更影响分析
- **行预算控制**：`agent_context_codex_memory()` 的行预算机制（限制加载的上下文行数）对 iOS 端的 token 预算管理有参考价值

---

## 七、orra

### 1. 项目概览与核心功能

orra 是一个 Go 语言实现的计划引擎，为 AI Agent 提供基于 PDDL 验证的计划编排。核心功能：

- **计划引擎**：`PlanEngine` 管理项目/服务/编排/领域约束
- **编排生命周期**：Prepare → Execute → Finalize 三阶段
- **LLM 分解**：`decomposeAction()` 使用 LLM 将动作分解为子任务
- **PDDL 验证**：通过 PDDL Validator 确保计划符合领域约束
- **向量缓存**：`VectorCache` 使用 `mat.VecDense` 缓存计划，相似度匹配复用
- **Saga 补偿**：`CompensationWorker` 实现补偿事务
- **实时状态**：WebSocket 实时推送 + Webhook 通知

### 2. 架构概览与模块

```
orra/planengine/
├── engine.go         # PlanEngine 核心结构 (649 行)
├── types.go          # 数据模型 (580 行)
├── orchestrate.go    # 编排逻辑 (1093 行)
└── storage/          # 存储接口
```

**核心设计模式**：
- **Three-Phase Orchestration**：Prepare（验证+分解）→ Execute（并发执行+监控）→ Finalize（通知+清理）
- **PDDL Validation**：生成 PDDL 领域+问题描述，通过外部验证器校验计划合法性
- **Vector Cache**：嵌入向量缓存 + 余弦相似度匹配，避免重复分解
- **Saga Compensation**：补偿事务 + 失败追踪
- **Exponential Backoff Retry**：Prepare 阶段最多重试 2 次

### 3. Memory System 实现

orra 通过 `VectorCache` 实现了一种"计划记忆"：

```go
type VectorCache struct {
    entries map[string]CacheEntry
}

type CacheEntry struct {
    Key       string
    Embedding *mat.VecDense  // gonum 向量
    Plan      ExecutionPlan
    CreatedAt time.Time
}
```

- `Similarity()`：余弦相似度匹配，用于查找历史相似计划
- 计划复用：当新动作与缓存中的动作相似度足够高时，直接复用历史分解方案

### 4. Skill System 实现

orra 不涉及 Skill System。

### 5. Planning/Goal System 实现

**编排准备**（`PrepareOrchestration()`，完整分析）：

1. **指数退避重试**：最多 2 次重试，延迟递增
2. **`attemptRetryablePreparation()`**：
   - LLM 分解动作 → 子任务列表
   - 任务验证：检查 `$taskID.key` 引用是否有效
   - PDDL 域验证：生成 PDDL 域+问题描述，通过 `PddlValidator` 校验
   - 领域约束匹配：`MatchingGroundingAgainstAction()` 使用 `SimilarityMatcher`
3. **提取 TaskZero**：`callingPlanMinusTaskZero()` 将 TaskZero 的字面输入转为引用

**编排执行**（`ExecuteOrchestration()`，完整分析）：

1. 创建执行日志（`Log`）
2. 启动 `TaskWorker` 池并发执行子任务
3. `ResultAggregator` 收集结果
4. `IncidentTracker` 跟踪异常
5. 并行组执行：`ParallelGroup` 支持子任务并行

**编排终结**（`FinalizeOrchestration()`，完整分析）：

1. 汇总结果
2. Webhook 通知
3. 补偿事务（失败时）
4. `FailedCompensation` 追踪

**领域约束**（`GroundingSpec`）：

```go
type GroundingSpec struct {
    Name        string
    Description string
    UseCases    []GroundingUseCase
}

type GroundingUseCase struct {
    Action      string
    Constraints []string
    Examples    []string
}
```

- PDDL 验证确保计划符合领域约束
- `SimilarityMatcher` 将动作匹配到领域用例

### 6. iOS 本地 Agent 移植启示

- **三阶段编排**：Prepare → Execute → Finalize 的生命周期模式适合 iOS 端的长时间任务管理
- **PDDL 验证**：在 iOS 端可简化为"规则引擎"验证，确保计划符合用户约束/设备限制
- **向量缓存**：`VectorCache` 的计划复用机制在 iOS 端特别有价值——避免重复调用 LLM 分解相似任务，节省 token 和时间
- **Saga 补偿**：补偿事务模式在 iOS 端可映射为"撤销栈"，支持用户回退操作
- **并行组**：`ParallelGroup` 的子任务并行执行模式可直接使用 Swift `TaskGroup` 实现
- **领域约束**：`GroundingSpec` 的领域特定规划约束可应用于 iOS 端的"安全区域"——限制 Agent 可执行的操作范围
- **WebSocket 实时状态**：iOS 端可替换为 Combine 框架或 async-stream 的状态流

---

## 八、shipit_agent

### 1. 项目概览与核心功能

shipit_agent 是一个功能完整的 Python Agent 框架，集成 LLM、工具、技能、RAG、记忆、会话、权限管理。核心功能：

- **Agent 数据类**：`Agent` 整合 LLM + 工具 + 技能 + RAG + 记忆 + 会话 + 策略 + 权限
- **30+ 内置工具**：`with_builtins()` 工厂方法提供文件/搜索/代码等内置工具
- **技能系统**：`SkillRegistry` / `FileSkillRegistry`，支持自动匹配和注入
- **RAG 集成**：自动将 RAG 检索工具和提示注入 Agent
- **权限引擎**：`PermissionEngine` 支持 default/acceptEdits/plan/bypass 模式
- **验证网络**：`VerifierNetwork` 工具调用前的否决检查
- **结构化输出**：`validate_with_retry()` 自动重试验证
- **推理运行时**：`ReasoningRuntime` 分解 + 证据 + 决策矩阵
- **Slash 命令**：从 `.shipit/commands/` 加载自定义命令

### 2. 架构概览与模块

```
shipit_agent/
├── agent.py              # Agent 数据类 (777 行)
├── skills/
│   ├── registry.py       # SkillRegistry / FileSkillRegistry
│   └── types.py          # 技能类型
├── permissions/
│   └── engine.py         # PermissionEngine
├── verifiers/
│   └── network.py        # VerifierNetwork
├── reasoning/
│   └── runtime.py        # ReasoningRuntime
├── rag/                  # RAG 集成
├── memory/               # 记忆管理
├── sessions/             # 会话管理
└── commands/             # Slash 命令
```

### 3. Memory System 实现

shipit_agent 通过 `Agent` 的 `memory` 字段集成记忆，但具体实现依赖外部记忆库（如 mem0）。

### 4. Skill System 实现

**技能注册与发现**（`agent.py` 完整分析）：

- `SkillRegistry` / `FileSkillRegistry`：文件系统技能注册表
- `find_relevant_skills(query)`：自动匹配相关技能（基于语义相似度）
- `apply_skill()`：将技能内容包装在 HTML 标记中注入提示
  ```
  <!-- skill:skill-id -->
  {skill_content}
  <!-- /skill:skill-id -->
  ```
- `tool_names_for_skills()`：技能注入内置工具名

**Agent 中的技能集成**：

```python
class Agent:
    skills: list[str] | None        # 显式技能列表
    default_skills: list[str]        # 默认技能
    
    def _selected_skills(self) -> list[str]:
        """合并显式 + 默认 + 自动匹配技能"""
    
    def _effective_prompt(self) -> str:
        """将技能内容包装在 HTML 标记中注入"""
    
    def _effective_tools(self) -> list[Tool]:
        """合并显式 + 技能注入的内置工具"""
    
    def _effective_max_iterations(self) -> int:
        """自动提升：4 → 8（当技能激活时）"""
```

- **HTML 标记注入**：`<!-- skill:skill-id -->...<!-- /skill:skill-id -->` 让 LLM 明确区分技能内容
- **自动迭代提升**：有技能时 `max_iterations` 从 4 提升到 8，给 Agent 更多步骤完成技能指导的任务
- **三种技能来源**：显式指定 + 默认技能 + 自动匹配（`find_relevant_skills`）

### 5. Planning/Goal System 实现

**plan() 模式**：

```python
def plan(self, prompt: str) -> PlanResult:
    """只读规划模式：
    - PermissionEngine(mode="plan") 禁止所有写入操作
    - Agent 只分析不执行
    - 返回结构化计划
    """
```

- `ReasoningRuntime`：分解 + 证据收集 + 决策矩阵，支持多方案比较

### 6. iOS 本地 Agent 移植启示

- **Agent 数据类模式**：`Agent` 将所有组件（LLM/工具/技能/RAG/记忆/权限）聚合为一个数据类的设计可直接移植到 Swift
- **HTML 标记注入**：`<!-- skill:... -->` 的技能注入方式简单高效，可直接在 iOS 端使用
- **自动迭代提升**：技能激活时自动增加迭代次数的策略值得 iOS 端参考
- **权限引擎**：`PermissionEngine` 的四种模式（default/acceptEdits/plan/bypass）适合 iOS 端的权限管理——特别是 plan 模式（只读分析）可用于预览
- **VerifierNetwork**：工具调用前的否决检查在 iOS 端特别重要——防止 Agent 执行危险操作
- **结构化输出验证**：`validate_with_retry()` 的重试验证模式适合 iOS 端与 LLM 的交互
- **工厂模式**：`with_builtins()` 和 `for_project()` 两个工厂方法提供了良好的默认配置入口

---

## 九、ms-agent

### 1. 项目概览与核心功能

ms-agent 是一个多 LLM Agent 框架，支持多种 Agent 类型和编排工作流。核心功能：

- **Agent 层次**：`Agent` ABC → `LLMAgent` / `CodeAgent` 子类
- **工作流编排**：`Workflow` ABC → `ChainWorkflow` / `DagWorkflow`
- **自动技能**：`AutoSkills` DAG 驱动的技能发现与执行
- **记忆管理**：`Memory` ABC → `DefaultMemory`
- **配置驱动**：OmegaConf 配置系统

### 2. 架构概览与模块

```
ms_agent/
├── agent/
│   ├── base.py           # Agent ABC
│   ├── llm_agent.py      # LLMAgent
│   └── code_agent.py     # CodeAgent
├── skill/
│   └── auto_skills.py    # AutoSkills (DAG 驱动)
├── memory/
│   └── base.py           # Memory ABC + DefaultMemory
├── workflow/
│   ├── base.py           # Workflow ABC
│   ├── chain.py          # ChainWorkflow
│   └── dag.py            # DagWorkflow
└── config/               # OmegaConf 配置
```

### 3. Memory System 实现

**Memory ABC**（`memory/base.py`，完整分析）：

```python
class Memory(ABC):
    @abstractmethod
    def run(self, messages: list) -> list:
        """处理消息列表，返回增强后的消息列表"""
```

- 极简接口：`run(messages) -> messages`
- `DefaultMemory`：默认实现
- `memory_mapping`：工具函数，将记忆实例映射到消息处理管线

### 4. Skill System 实现

**AutoSkills**（`skill/auto_skills.py`，部分分析）：

- **DAG 驱动的技能执行**：使用有向无环图管理技能依赖和执行顺序
- **核心类型**：
  - `SkillContainer`：技能容器
  - `SkillSchema`：技能模式定义
  - `SkillContext`：技能执行上下文
- **LLM 驱动的技能分析**：
  - 查询分析：理解用户意图需要哪些技能
  - DAG 构建：确定技能执行顺序和依赖
  - 过滤：快速过滤（fast）+ 深度过滤（deep）
  - 执行错误分析：当技能执行失败时分析原因
- **混合检索**：`HybridRetriever` 用于技能搜索
- **结果类型**：`DAGExecutionResult` / `SkillDAGResult`

### 5. Planning/Goal System 实现

**工作流系统**（`workflow/base.py`，完整分析）：

```python
class Workflow(ABC):
    @abstractmethod
    def build_workflow(self): ...
    
    @abstractmethod
    def run(self): ...
```

- `ChainWorkflow`：线性链式执行
- `DagWorkflow`：DAG 并行执行
- 配置加载：从目录或 DictConfig 加载，支持 `load_cache` 和 `mcp_server_file`

### 6. iOS 本地 Agent 移植启示

- **极简 Memory 接口**：`run(messages) -> messages` 的设计非常适合 iOS 端——最小化协议约束，允许灵活实现
- **DAG 技能执行**：`AutoSkills` 的 DAG 驱动技能执行比线性执行更高效，适合 iOS 端的复杂任务场景
- **LLM 驱动技能分析**：使用 LLM 分析查询意图 → 构建技能 DAG 的方式在 iOS 端可行，但需注意 token 消耗
- **混合检索**：`HybridRetriever` 的模式可参考，iOS 端可实现关键词+语义混合的技能检索
- **Workflow 抽象**：Chain/Dag 两种基本工作流模式可直接移植到 Swift
- **OmegaConf 配置**：iOS 端可替换为 Swift 的 `Codable` + JSON/Plist 配置

---

## 十、跨项目综合分析

### 1. Memory System 演进谱系

```
极简接口                    Token 预算                多层向量存储
─────────                  ─────────                ──────────
ms-agent.Memory            langmem.Summarization    mem0.Memory
  run(messages)->messages   Node                     20+ 向量后端
                            RunningSummary           BM25+向量混合
                            增量摘要                  实体过滤
                            
文件即记忆                  计划缓存
─────────                  ─────────
saber.agent_context        orra.VectorCache
  MEMORY.md                mat.VecDense
  CLAUDE.md                余弦相似度
  SOUL.md                  计划复用
```

**关键演进方向**：
1. **接口抽象**：从极简 `run(messages)` 到完整 CRUD（mem0 `MemoryBase`）
2. **存储后端**：从文件系统（saber）到向量数据库（mem0 20+ 后端）
3. **检索策略**：从无检索到 BM25+向量混合检索（mem0）
4. **摘要策略**：从无摘要到 token 预算感知增量摘要（langmem）
5. **类型扩展**：从纯事实记忆到事实+过程双类型（mem0 MemoryType）

### 2. Skill System 演进谱系

```
CLI 工具           运行时框架              Agent 集成              LLM 驱动
─────────          ──────────             ──────────             ─────────
openskills         skillkit               shipit_agent            ms-agent
  list/install       渐进式披露              HTML 标记注入           DAG 驱动
  AGENTS.md          脚本执行引擎            自动匹配                LLM 分析
  项目/全局级         MCPB 插件              迭代自动提升             混合检索
                     安全控制                验证网络                 过滤管线
```

**关键演进方向**：
1. **发现机制**：从 CLI 手动安装（openskills）到文件系统自动扫描（skillkit）到语义自动匹配（shipit_agent）
2. **执行能力**：从无执行（openskills）到脚本执行引擎（skillkit 5 种语言）到 DAG 编排（ms-agent）
3. **安全控制**：从基础（openskills）到完整（skillkit 路径遍历/setuid/超时/截断）到验证网络（shipit_agent）
4. **集成深度**：从独立工具（openskills）到 Agent 组件（skillkit）到深度集成（shipit_agent HTML 注入 + 迭代提升）

### 3. Planning/Goal System 演进谱系

```
DAG 目标图           计划引擎                工作流
─────────           ─────────              ──────
goalweaver          orra                   ms-agent
  networkx.DiGraph    PDDL 验证              Chain/Dag
  自适应规划          Saga 补偿              OmegaConf
  事件驱动重写        向量缓存              
  并发批执行          领域约束              
```

**关键演进方向**：
1. **计划表示**：从简单 DAG（goalweaver `networkx.DiGraph`）到 PDDL 验证计划（orra）
2. **调度策略**：从优先级排序（goalweaver）到领域约束匹配（orra `GroundingSpec`）
3. **容错机制**：从状态标记（goalweaver `GoalStatus.FAILED`）到 Saga 补偿（orra `CompensationWorker`）
4. **计划复用**：从无缓存到向量缓存（orra `VectorCache`）
5. **验证**：从无验证到 PDDL 领域验证（orra `PddlValidator`）

### 4. 对 iOS 本地 Agent 的架构建议

#### Memory 层

| 组件 | 推荐方案 | 参考来源 |
|------|---------|---------|
| 存储后端 | SQLite + vec 扩展 或 FAISS (C++) | mem0 多后端 Factory |
| 记忆接口 | `run(messages) -> messages` + CRUD 扩展 | ms-agent 极简 + mem0 完整 |
| 摘要策略 | Token 预算感知增量摘要 | langmem RunningSummary |
| 检索策略 | BM25 + 向量混合检索 | mem0 score_and_rank |
| 记忆类型 | 事实记忆 + 过程记忆 | mem0 MemoryType |
| 上下文加载 | 文件即记忆 + Agent 类型感知 | saber agent_context |

#### Skill 层

| 组件 | 推荐方案 | 参考来源 |
|------|---------|---------|
| 技能格式 | Markdown + YAML 前置元数据 | skillkit SkillParser |
| 加载策略 | 渐进式披露（元数据优先，内容懒加载） | skillkit SkillMetadata → Skill |
| 发现机制 | 文件系统扫描 + 语义自动匹配 | skillkit + shipit_agent |
| 注入方式 | HTML 标记注入 | shipit_agent apply_skill |
| 执行引擎 | Swift 闭包 + URL Scheme（替代脚本） | skillkit ScriptExecutor |
| 安全控制 | 路径验证 + 超时 + 输出截断 + 权限检查 | skillkit 安全控制全套 |
| 冲突解决 | 优先级排序（系统 > 用户 > 插件） | skillkit SourceType |

#### Planning 层

| 组件 | 推荐方案 | 参考来源 |
|------|---------|---------|
| 目标表示 | DAG + 优先级 + 状态 | goalweaver GoalGraph |
| 调度策略 | 优先级 + 入度 + 创建时间排序 | goalweaver AdaptivePlanner |
| 并发执行 | Swift TaskGroup | goalweaver Orchestrator |
| 领域约束 | 简化规则引擎（替代 PDDL） | orra GroundingSpec |
| 计划缓存 | 嵌入向量 + 余弦相似度 | orra VectorCache |
| 容错机制 | 状态标记 + 撤销栈（替代 Saga） | goalweaver + orra |
| 空闲检测 | 迭代计数 + 资源监控 | goalweaver 空闲循环检测 |
| 只读规划 | 权限引擎 plan 模式 | shipit_agent PermissionEngine |

#### 权限与安全

| 组件 | 推荐方案 | 参考来源 |
|------|---------|---------|
| 权限模式 | default / acceptEdits / plan / bypass | shipit_agent PermissionEngine |
| 工具验证 | 前置否决检查 | shipit_agent VerifierNetwork |
| 输出验证 | 结构化输出 + 重试验证 | shipit_agent validate_with_retry |
| 脚本安全 | 路径遍历/超时/输出截断 | skillkit ScriptExecutor |

---

## 附录：核心文件索引

| 项目 | 核心文件 | 行数 | 分析深度 |
|------|---------|------|---------|
| mem0 | `memory/base.py` | ~100 | 完整 |
| mem0 | `memory/main.py` | ~400+ | 前 400 行 |
| langmem | `short_term/summarization.py` | ~860 | 完整 |
| langmem | `knowledge/extraction.py` | ~85KB | 部分 |
| skillkit | `core/models.py` | ~713 | 完整 |
| skillkit | `core/discovery.py` | ~434 | 完整 |
| skillkit | `core/parser.py` | ~444 | 完整 |
| skillkit | `core/manager.py` | ~57.8KB | 部分 |
| skillkit | `core/processors.py` | ~407 | 完整 |
| skillkit | `core/scripts.py` | ~1239 | 完整 |
| openskills | `src/cli.ts` | ~200 | 完整 |
| openskills | `src/types.ts` | ~50 | 完整 |
| goalweaver | `goal_graph.py` | ~150 | 完整 |
| goalweaver | `planner.py` | ~100 | 完整 |
| goalweaver | `types.py` | ~100 | 完整 |
| goalweaver | `agent.py` | ~80 | 完整 |
| goalweaver | `runtime.py` | ~200 | 完整 |
| saber | `R/fn_graph.R` | ~80 | 完整 |
| saber | `R/agent_context.R` | ~404 | 完整 |
| saber | `R/blast.R` | ~120 | 完整 |
| saber | `R/briefing.R` | ~80 | 完整 |
| orra | `planengine/engine.go` | ~649 | 完整 |
| orra | `planengine/types.go` | ~580 | 完整 |
| orra | `planengine/orchestrate.go` | ~1093 | 完整 |
| shipit_agent | `agent.py` | ~777 | 完整 |
| ms-agent | `agent/base.py` | ~60 | 完整 |
| ms-agent | `memory/base.py` | ~40 | 完整 |
| ms-agent | `skill/auto_skills.py` | ~80.9KB | 部分 |
| ms-agent | `workflow/base.py` | ~80 | 完整 |
