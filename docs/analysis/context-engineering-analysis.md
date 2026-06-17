# Context Engineering 深度分析报告

> 分析对象：UltraContext、Zenbase、ContextDB 论文
> 分析日期：2026-06-17

---

## 一、UltraContext

### 1. 项目概述

UltraContext 是一个开源的**跨 Agent 上下文共享平台**，核心理念是 **"Same Context, Everywhere"**。它解决的问题是：不同 AI Agent（Claude Code、Codex、OpenClaw 等）之间上下文割裂，一个 Agent 知道的东西另一个不知道。

核心功能：
- **CLI Daemon**：自动捕获所有 Agent 的会话上下文
- **MCP Server**：让任何 MCP 兼容 Agent 获取其他 Agent 的上下文
- **Context API**：类 Git 的上下文工程 API，支持存储、版本化、检索

### 2. 架构概览

```
UltraContext
├── packages/
│   ├── core/           # 核心引擎（HTTP/DB 无关的纯逻辑）
│   │   ├── storage.ts      # StorageAdapter 接口定义
│   │   ├── context-chain.ts # 链表数据结构 + 版本控制
│   │   ├── message-view.ts  # 消息视图类型
│   │   ├── ops/             # CRUD 操作（create/append/update/delete/get/list）
│   │   └── result.ts        # Result 类型（ok/err）
│   └── storage/        # 存储适配器
│       ├── drizzle.ts       # PostgreSQL (Drizzle ORM)
│       ├── supabase.ts      # Supabase REST
│       └── sqlite/          # SQLite (libsql, local-first)
├── apps/
│   ├── api/            # Hono HTTP API (Cloudflare Workers)
│   ├── mcp-server/     # MCP 服务器（stdio + HTTP）
│   ├── js-sdk/         # JavaScript SDK
│   ├── python-sdk/     # Python SDK
│   └── docs/           # 文档站
```

**核心类/接口**：
- `StorageAdapter`：抽象存储接口，定义 findNodesByContextId、insertNodes、transaction 等
- `NodeRow`：统一数据模型（public_id, type, content, metadata, prev_id, context_id, parent_id）
- `MessageView`：消息响应视图（content + id + index + metadata）
- `Result<T>`：传输无关的结果类型（ok: true | ok: false + ErrorCode）

### 3. Context Engineering 核心技术

#### 3.1 链表式上下文链（Context Chain）

核心数据结构是**双向隐式链表**。每个 Context 由多个 Node 组成：

```
Root Node (type='context', context_id=null)
  └── Head Node (type='context', context_id=root_id, prev_id=prev_head)
        ├── Message Node (type='message', prev_id=prev_msg, parent_id=null)
        ├── Message Node ...
        └── Message Node ...
```

关键设计：
- **Root Node**：顶层容器，`context_id = null` 标识根节点
- **Head Node**：版本指针，每个 Head 代表一个版本快照
- **Message Node**：实际消息，通过 `prev_id` 组成链表
- **parent_id**：指向原始节点（用于 fork 关系追踪）

`orderNodes()` 函数通过 `prev_id` 链重建有序消息序列，类似 Git 的 commit chain。

#### 3.2 Copy-on-Write 版本控制

更新和删除操作使用 **Copy-on-Write** 语义：

1. **Update**：创建新 Head，复制所有消息节点（修改的节点合并变更，未修改的节点直接引用原 content）
2. **Delete**：创建新 Head，仅复制幸存的消息节点
3. **Append**：不创建新版本，直接在当前 Head 链尾部追加

```
v0 (create)     v1 (update msg1)     v2 (delete msg2)
├── msg1        ├── msg1 ← modified  ├── msg1
├── msg2        ├── msg2
```

每个 Head 的 `metadata` 记录操作类型（create/update/delete）和受影响的节点 ID。

#### 3.3 时间旅行与 Fork

- **版本检索**：`getContext(id, {version: N})` 返回第 N 个版本的完整消息列表
- **时间点检索**：`getContext(id, {before: ISO8601})` 返回某个时间点的状态
- **索引切片**：`getContext(id, {at: N})` 返回前 N+1 条消息
- **Fork**：`createContext({from: sourceId, version/at/before})` 从源 context 的任意时间点创建分支

#### 3.4 Schema-Free 消息模型

消息是完全无模式的 JSON 对象，只保留 `metadata`、`id`、`index` 三个内部字段。用户可以存储任意结构的消息，与任何 LLM 框架兼容。

### 4. Context Window 管理

UltraContext 的上下文窗口管理策略体现在其文档中描述的**五种上下文工程技巧**：

1. **Compaction（压缩）**：可逆减少——剥离可从外部状态重建的信息。文件写入？保留路径，丢弃内容。搜索？保留查询，丢弃结果。无信息丢失，只是外部化。

2. **Summarization（摘要）**：不可逆减少——仅在压缩收益微小时使用。关键技巧：使用结构化 schema（待填充字段），而非自由格式 prompt。保留最后几步工具调用的完整细节，让模型知道它在哪里停下的。

3. **Offloading（卸载）**：将上下文移出窗口——转储到文件，按需通过路径或 ID 检索。预摘要上下文也可保存为日志文件，模型稍后可 grep。

4. **Isolation（隔离）**：
   - *通信隔离*：子 Agent 仅获得指令，仅返回结果。适用于清晰的、有边界的任务。
   - *上下文共享*：子 Agent 看到完整历史，但有自己的系统 prompt。适用于需要前序上下文的任务。权衡：更大的 pre-fill，无 KV cache 复用。

5. **Caching（缓存）**：稳定的上下文前缀启用 KV cache 复用。动态工具注入会打破缓存。保持原子工具固定；将扩展性卸载到沙箱工具或代码执行。

### 5. Context Compression

UltraContext 本身不直接做内容压缩，但提供了**上下文版本的索引切片**机制：
- `at` 参数：只取前 N 条消息，减少上下文窗口占用
- `before` 参数：只取某个时间点之前的消息
- `version` 参数：回退到特定版本

实际压缩策略由调用方（Agent 框架）实现，UltraContext 提供了细粒度的上下文检索原语。

### 6. Context Retrieval

UltraContext 的检索策略：

1. **元数据过滤**：通过 `ContextFilters` 支持 source、user_id、host、project_path、session_id、时间范围过滤
2. **版本遍历**：通过 `getVersions()` 获取所有版本头，支持按版本号、时间点检索
3. **MCP 工具**：
   - `list_contexts`：列出最近的 Agent 上下文，支持多种过滤
   - `get_context_messages`：获取特定上下文的所有消息
   - `get_recent_activity`：快捷获取最近活动

### 7. 对 iOS 本地 Agent 的启示

| 设计模式 | 可移植性 | 说明 |
|---------|---------|------|
| **链表式 Context Chain** | ★★★★ | SQLite 上的链表遍历高效，适合本地存储；Copy-on-Write 版本控制确保不可变历史 |
| **Schema-Free 消息** | ★★★★★ | 直接复用，iOS 可用 Codable JSON 存储 |
| **StorageAdapter 抽象** | ★★★★ | 接口清晰，可移植为 Swift Protocol，支持 SQLite/内存双实现 |
| **SQLite 本地优先** | ★★★★★ | 直接使用 SQLite 作为本地存储，libsql/GRDB 均可 |
| **版本化上下文** | ★★★★ | 对话历史版本控制，支持回退和时间旅行，在本地实现低延迟 |
| **Fork/Clone 上下文** | ★★★ | 允许用户从历史对话分叉探索，适合 iOS 的多任务场景 |
| **MCP 协议** | ★★ | MCP 是网络协议，iOS 本地 Agent 可改为进程内函数调用 |
| **Compaction 策略** | ★★★★★ | 压缩/卸载/摘要等上下文工程策略可直接应用于移动端 token 预算管理 |

---

## 二、Zenbase

### 1. 项目概述

Zenbase 是一个 **LLM Prompt 优化框架**，核心理念是通过自动化的 Few-Shot 学习来优化 LLM 函数。它不关心上下文存储和检索，而是关注**如何选择最优的示例（demos）注入到 prompt 中**，以最大化 LLM 输出质量。

核心功能：
- **LabeledFewShot**：标注数据驱动的 Few-Shot 优化
- **BootstrapFewShot**：自举式 Few-Shot 优化（多层 prompt 链）
- **预定义分类器**：开箱即用的单分类器、合成数据生成
- **多平台适配**：LangSmith、Arize、LangFuse、Parea、Lunary、JSON

### 2. 架构概览

```
Zenbase
├── core/
│   └── managers.py         # ZenbaseTracer（追踪+优化参数注入）
├── types.py                # 核心类型系统
│   ├── Dataclass            # 序列化基类
│   ├── LMDemo              # 输入-输出示例
│   ├── LMZenbase           # 优化状态（task_demos + model_params）
│   ├── LMRequest           # 请求（zenbase + inputs）
│   ├── LMResponse          # 响应（outputs + attributes）
│   ├── LMCall              # 调用记录（function + request + response）
│   └── LMFunction          # 核心抽象：可优化的 LLM 函数
├── optim/
│   ├── base.py             # LMOptim 基类
│   └── metric/
│       ├── labeled_few_shot.py  # LabeledFewShot 优化器
│       ├── bootstrap_few_shot.py # BootstrapFewShot 优化器
│       └── types.py             # 评估结果类型
├── adaptors/               # 平台适配层
│   ├── json/               # 纯 JSON 适配
│   ├── langchain/          # LangChain 适配
│   ├── langfuse_helper/    # LangFuse 适配
│   ├── arize/              # Arize 适配
│   ├── parea/              # Parea 适配
│   └── lunary/             # Lunary 适配
└── predefined/
    ├── single_class_classifier/  # 单分类器
    └── generic_lm_function/      # 通用 LLM 函数优化器
```

**核心类**：
- `LMFunction[Inputs, Outputs]`：可调用的 LLM 函数包装，携带 zenbase 状态和调用历史
- `LMZenbase`：优化状态容器（task_demos + model_params）
- `LMDemo`：输入-输出示例对
- `LMOptim`：优化器基类，定义 `perform()` 接口
- `ZenbaseTracer`：追踪管理器，记录函数调用并注入优化参数

### 3. Context Engineering 核心技术

#### 3.1 Few-Shot 上下文优化

Zenbase 的核心是**动态选择最优 few-shot 示例**：

**LabeledFewShot** 算法：
1. 从标注数据集中随机采样 N 组 demo（每组 shots 个示例）
2. 对每组 demo 构造 `LMZenbase(task_demos=demos)`
3. 用候选函数在验证集上评估，选出得分最高的 demo 组合
4. 支持多轮（rounds）和并行（concurrency）

**BootstrapFewShot** 算法：
1. 先用 LabeledFewShot 训练 teacher 模型
2. 用 teacher 在训练集上验证，过滤掉失败的 demo
3. 运行验证通过的 demo，收集所有中间层的输入输出作为 trace
4. 将 trace 合并为每层的 few-shot demo
5. 注入到 student 模型的对应层中

#### 3.2 LMFunction 抽象

`LMFunction` 是一个函数包装器，核心创新是**将优化状态与函数绑定**：

```python
class LMFunction:
    fn: Callable[[LMRequest], Outputs]  # 原始函数
    zenbase: LMZenbase                  # 优化状态
    history: deque[LMCall]              # 调用历史

    def __call__(self, inputs):
        request = LMRequest(zenbase=self.zenbase, inputs=inputs)
        response = self.fn(request)
        self.history.append(LMCall(self, request, response))
        return response
```

函数签名统一为 `(LMRequest) -> Outputs`，`LMRequest` 包含 `zenbase`（当前优化状态）和 `inputs`。函数内部可以读取 `request.zenbase.task_demos` 来获取 few-shot 示例。

#### 3.3 Trace-Based 优化注入

`ZenbaseTracer` 通过 Python 的 context manager 机制，在运行时注入优化参数：

1. 装饰 `@tracer.trace_function` 包装函数
2. 运行时检查 `optimized_args` 字典
3. 如果当前函数名在 `optimized_args` 中，将预计算的 zenbase（包含最优 demos）注入到 request 中
4. 函数内部自然读取到优化后的 few-shot 示例

### 4. Context Window 管理

Zenbase 不直接管理上下文窗口，但通过 **Few-Shot 选择**间接影响：
- `shots` 参数控制注入的 demo 数量（默认 5 个）
- 每个示例包含 input + output 的完整文本
- 过多的 shots 会消耗大量 token，Zenbase 通过评估选择最有效的子集

### 5. Context Compression

Zenbase 的"压缩"策略是**选择性注入**：
- 不将所有示例塞入 prompt，而是通过评估选出最有效的少量示例
- BootstrapFewShot 进一步过滤：只保留 teacher 验证通过的 demo 对应的 trace
- 压缩比取决于 shots/total_demos 比率

### 6. Context Retrieval

Zenbase 的"检索"是**Demo 选择**：
- 随机采样 + 评估排序（LabeledFewShot）
- Teacher 模型验证过滤（BootstrapFewShot）
- 无语义相似度检索，完全依赖评估指标驱动

### 7. 对 iOS 本地 Agent 的启示

| 设计模式 | 可移植性 | 说明 |
|---------|---------|------|
| **LMFunction 包装器** | ★★★★ | Swift 可用泛型函数包装，将优化状态与函数绑定 |
| **Few-Shot 优化** | ★★★★ | 在设备端评估不同 demo 组合，选择最优 few-shot |
| **Trace-Based 注入** | ★★★ | iOS 需要简化 trace 机制，但优化参数注入的思路可借鉴 |
| **评估驱动选择** | ★★★★★ | 用本地评估指标（无需云）选择最优 prompt 配置 |
| **多平台适配层** | ★★★ | 适配器模式在 iOS 上可简化为 Provider Protocol |
| **cloudpickle 持久化** | ★★ | 不适用于 iOS，需替换为 Codable/JSON |

---

## 三、ContextDB 论文

### 1. 项目概述

ContextDB 是一个**统一的 Agent 记忆操作系统**，论文标题为"ContextDB: A Unified Context Layer for AI Agents — Replacing the Patchwork with a Memory Operating System"。

论文基于对 **200+ 篇 Agent 记忆论文**的分析，提出将三种记忆形式（token-level、parametric、latent）、三种记忆功能（factual、experiential、working）和三种动态过程（formation、evolution、retrieval）统一到一个模块化框架中。

### 2. 架构概览

ContextDB 架构由以下核心模块组成：

1. **Multi-Graph Memory Representation**：多图记忆表示
   - 语义图（Semantic Graph）：基于嵌入相似度
   - 时间图（Temporal Graph）：基于事件时间序列
   - 因果图（Causal Graph）：基于因果关系推理
   - 实体图（Entity Graph）：基于实体关系

2. **RL-Trained Memory Manager**：强化学习训练的记忆管理器
   - 学习最优记忆操作：ADD、UPDATE、DELETE、NOOP
   - 仅需约 150 个训练样本即可超越启发式规则
   - 基于 PPO/GRPO 训练

3. **Segment-Level Memory Formation**：分段级记忆形成
   - 压缩即去噪（Compression-as-Denoising）
   - 检索精度提升 12-18%
   - 60-70% 压缩率，80-90% token 节省

4. **Multi-Agent Memory Sharing**：多 Agent 记忆共享
   - 冲突解决机制
   - 角色感知路由
   - 隐私边界

5. **Privacy-by-Design**：隐私设计
   - PII 检测
   - 可配置保留策略
   - 审计追踪

### 3. Context Engineering 核心技术

#### 3.1 记忆三维度框架

**Forms（形式）**：
- **Token-level**：上下文窗口中的显式文本
- **Parametric**：模型权重中的隐式知识
- **Latent**：KV cache、隐藏状态中的激活

**Functions（功能）**：
- **Factual**：事实性记忆（用户资料、产品信息）
- **Experiential**：经验性记忆（解决模式、工作流模板）
- **Working**：工作记忆（当前任务状态、活跃上下文）

**Dynamics（动态）**：
- **Formation**：记忆如何形成（分段级 vs 轮次级 vs 会话级）
- **Evolution**：记忆如何演化（更新、合并、归档）
- **Retrieval**：记忆如何检索（查询自适应）

#### 3.2 八大研究主题

论文从 200+ 篇论文中提炼出 8 个核心主题：

1. **记忆应该是系统层，而非应用嵌入**：共享记忆层优于每个 Agent 独立构建记忆
2. **图表示是赢家**：多图方法在多跳推理、时间查询、实体检索上持续优于平面向量存储（提升达 20%）
3. **压缩是去噪，不是有损**：压缩后存储反而提升检索精度 12-18%
4. **学习策略碾压启发式**：RL 训练的记忆策略用 152 个样本就超越 Mem0 48% F1
5. **双时性是生产必需**：事件时间 vs 摄入时间，两者必须区分
6. **分段级形成优于轮次/会话级**：过滤噪声后记忆质量更高
7. **隐私是首要关注**：200+ 论文中不到 5 篇将隐私作为一等公民
8. **多 Agent 记忆尚处早期**：角色路由和冲突解决是关键

### 4. Context Window 管理

ContextDB 对上下文窗口管理的关键洞见：

1. **工作记忆必须尊重 Token 预算**：
   - 即使 128K+ token 模型，填满窗口也是浪费和适得其反的
   - ContextDB 采用"caller context snapshot"模式：预计算 400-500 token 的压缩快照

2. **Pre-ring 优化**：
   - 在来电响铃的 3-5 秒间隔内预计算检索
   - 实体图查询 (~50ms) → 时间排序 (~10ms) → 压缩 (~30ms) = 总计 ~90ms
   - 首次响应延迟从 2.1s 降至 0.4s

3. **压缩策略**：
   - 60-70% 压缩率是最优区间
   - 自然语言的冗余（填充词、犹豫短语、对话寒暄）在嵌入空间中充当噪声
   - 移除这些噪声产生更干净、更有区分度的向量

### 5. Context Compression

**Compression-as-Denoising** 是 ContextDB 的核心创新：

1. **为什么压缩反而提升精度**：
   - 自然语言充满冗余："thanks for calling"、"let me check that" 等在嵌入空间中是噪声
   - 移除噪声后，检索的 top-k 更可能相关
   - RL 管理的 300 条记忆 > 原始存储的 3000 条记忆（F1 提升 15-20%）

2. **分段级形成**：
   - 轮次级存储：每天 ~500 条，一月后 15000 条，大部分是噪声
   - 分段级存储 + 压缩：每天 ~65 条，一月后 ~2000 条高信号项
   - 解决步骤从排名 8-12 提升到排名 1-3

3. **Token 节省**：
   - 高达 90% token 节省
   - 同时保持或提升检索质量

### 6. Context Retrieval

ContextDB 的检索策略是**查询自适应**的：

| 查询类型 | 所需图结构 | 示例 |
|---------|----------|------|
| 实体查找 | 实体图 | "Alex 的邮箱是什么？" |
| 时间遍历 | 时间图 | "维修后发生了什么？" |
| 因果推理 | 因果图 | "升级为什么失败？" |
| 语义相似 | 语义图 | "找类似的对话" |

**关键洞见**：纯嵌入相似度检索（大多数 RAG 管道的默认方式）在时间和因果查询上静默失败——它们返回语义相关但时间或因果无关的记忆。

**多图融合检索流程**：
1. 查询分类（识别查询类型）
2. 选择对应图结构
3. 图遍历 + 排序
4. 结果融合 + 压缩
5. 注入上下文窗口

### 7. 对 iOS 本地 Agent 的启示

| 设计模式 | 可移植性 | 说明 |
|---------|---------|------|
| **记忆三维度框架** | ★★★★ | iOS Agent 需要 factual（用户偏好）+ experiential（操作模式）+ working（当前任务）三层记忆 |
| **多图表示** | ★★★ | 本地可简化为：实体图（CoreData）+ 时间线（有序队列），因果图和语义图可用轻量替代 |
| **RL 训练的记忆管理** | ★★ | 在设备端训练 RL 代价大，可用启发式规则启动 + 云端训练后下发 |
| **压缩即去噪** | ★★★★★ | 移动端 token 预算更紧张，分段级形成 + 压缩是最有价值的优化 |
| **Pre-ring 预计算** | ★★★★★ | iOS Agent 在用户操作间隙预计算上下文快照，避免操作时延迟 |
| **双时性** | ★★★★ | 本地事件时间 vs 同步时间必须区分，适合离线场景 |
| **查询自适应检索** | ★★★★ | 根据查询类型选择不同检索策略，本地可实现轻量版 |
| **角色路由** | ★★★ | 多 Agent 场景下的记忆边界，iOS 可简化为 App/Extension 间的数据隔离 |
| **隐私设计** | ★★★★★ | iOS 的 App Sandbox + Keychain + Data Protection 天然支持 PII 检测和保留策略 |

---

## 四、综合对比

| 维度 | UltraContext | Zenbase | ContextDB |
|------|-------------|---------|-----------|
| **核心关注** | 跨 Agent 上下文共享 | Prompt Few-Shot 优化 | 统一记忆操作系统 |
| **数据模型** | 链表 + Copy-on-Write | Demo 列表 + 评估结果 | 多图（语义/时间/因果/实体） |
| **版本控制** | 自动版本化（Git-like） | 无 | 双时性（事件时间 + 摄入时间） |
| **压缩策略** | 索引切片（at/before） | 选择性注入（shots 选择） | 压缩即去噪（60-70% 压缩率） |
| **检索策略** | 元数据过滤 + 版本遍历 | 评估驱动排序 | 查询自适应多图检索 |
| **存储后端** | PostgreSQL/SQLite/Supabase | 内存 + cloudpickle | 图数据库（未开源） |
| **MCP 集成** | 原生支持 | 无 | 无 |
| **多 Agent 支持** | 跨 Agent 共享 | 单 Agent 优化 | 多 Agent 记忆共享协议 |
| **隐私** | API Key 隔离 | 无 | PII 检测 + 保留策略 + 审计 |
| **成熟度** | 生产可用（开源） | 实验性（0.0.22） | 论文阶段（未开源） |

---

## 五、对 iOS 本地 Agent 的综合启示

### 5.1 最值得采纳的设计

1. **UltraContext 的链表式上下文 + Copy-on-Write 版本控制**
   - SQLite 上的轻量实现，完全离线可用
   - 对话历史不可变，支持回退和时间旅行
   - Schema-Free JSON 消息模型，灵活适配各种 Agent 任务

2. **ContextDB 的"压缩即去噪"理念**
   - 移动端 token 预算最紧张，这是最高优先级的优化
   - 分段级记忆形成 > 轮次级 > 会话级
   - 60-70% 压缩率不仅节省 token，还提升检索精度

3. **ContextDB 的查询自适应检索**
   - 不同查询类型需要不同检索策略
   - 本地可实现轻量版：实体查询 → CoreData，时间查询 → 有序队列，语义查询 → 嵌入相似度

4. **Zenbase 的评估驱动 Few-Shot 选择**
   - 在设备端评估不同 demo 配置，选择最优 prompt
   - 不需要大量训练数据，150 个样本即可启动

### 5.2 架构建议

```
iOS Local Agent Context Layer
├── Storage Layer
│   ├── SQLite (GRDB)           ← UltraContext 的链表模型
│   ├── CoreData (Entity Graph)  ← ContextDB 的实体图
│   └── Keychain (PII)           ← ContextDB 的隐私层
├── Memory Manager
│   ├── Formation (Segment-Level) ← ContextDB 的压缩即去噪
│   ├── Evolution (Heuristic → RL) ← ContextDB 的记忆演化
│   └── Compression (60-70%)       ← ContextDB 的压缩策略
├── Retrieval Engine
│   ├── Entity Lookup             ← 实体图
│   ├── Temporal Traversal        ← 时间线
│   ├── Semantic Search (Embedding) ← 语义相似度
│   └── Query Router              ← 查询自适应
├── Context Builder
│   ├── Token Budget Manager      ← 窗口预算管理
│   ├── Snapshot Pre-computation   ← Pre-ring 模式
│   └── Few-Shot Selector          ← Zenbase 的评估驱动选择
└── Version Control
    ├── Copy-on-Write History      ← UltraContext 的版本化
    └── Fork/Clone                 ← 对话分叉
```

### 5.3 关键技术决策

1. **存储**：SQLite + CoreData 双引擎，SQLite 存对话链（UltraContext 模型），CoreData 存实体关系
2. **压缩**：分段级形成 + 结构化压缩，目标 60-70% 压缩率
3. **检索**：查询分类 + 多策略检索，优先保证实体和时间查询的准确性
4. **版本**：Copy-on-Write 不可变历史，支持回退和 fork
5. **隐私**：PII 检测 + 分级存储（Keychain / Sandbox / 内存）
6. **优化**：Few-Shot 选择用本地评估驱动，RL 策略用云端训练下发
7. **预计算**：用户操作间隙预计算上下文快照，确保操作时零延迟
