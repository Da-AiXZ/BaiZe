# 论文与文档分析报告

> 本报告对 63 篇论文/文档按主题分类，提取核心论点、关键技术方法及对 iOS 本地编程智能体设计的启示。
> 链接 #8 (51CTO) 和 #1 (LLM-Harness PDF) 无法访问，已跳过。#12 (arxiv 2606.14674) 因速率限制未能获取。

---

## 一、Harness 相关

### 1.2 LangChain Blog: The Anatomy of an Agent Harness

**核心论点**：Agent = Model + Harness。Harness 是"如果你不是模型，那你就是 Harness"。模型只负责推理，Harness 提供行动场所、记忆、校验和规则约束。Harness 不会因为模型变强而消失——精心配置的环境、正确的工具、持久状态和验证循环能使任何模型更高效。

**关键技术**：
- **文件系统**：持久存储、自然协作面、Git 版本控制，增量卸载上下文
- **Bash + 代码执行**：给模型一台"计算机"，让它动态设计自己的工具
- **沙箱与工具**：安全隔离执行、命令白名单、网络隔离、自验证循环（写代码→运行测试→检查日志→修复错误）
- **记忆与搜索**：AGENTS.md 记忆文件标准、Web Search 和 MCP 工具
- **对抗上下文腐烂**三大策略：Compaction（压缩）、Tool Call Offloading（工具调用卸载）、Skills（渐进式披露）
- **长时域自主执行**：文件系统+Git、Ralph Loop（拦截提前退出）、规划文件、自验证
- **模型训练与 Harness 设计的耦合**：Claude Code、Codex 在后训练中纳入 Harness，形成反馈循环

**iOS 启示**：
- iOS 本地编程 Agent 需要精心设计 Harness 层，不能仅依赖模型能力
- 文件系统访问需设计为安全沙箱，遵循 iOS 沙箱机制
- 上下文压缩策略对本地有限内存环境尤为重要
- AGENTS.md 等项目配置文件应作为 iOS Agent 的标准入口

---

### 1.3 DataCamp: 什么是 Agent Harness？

**核心论点**：Harness 是围绕语言模型的软件层：工具、内存、状态、执行、防护栏与可观测性。Harness ≠ 框架 ≠ 运行时——三者处于不同抽象层级。模型没变但 Harness 不一样，产出质量可能差很多。

**关键技术**：
- Harness 核心组件：系统提示与行为规则、工具（MCP 标准接口）、记忆与状态、执行环境（沙箱容器）、编排与规划、防护栏与权限、可观测性与追踪
- 三层结构：框架（提供构件）→ 运行时（持久执行）→ Harness（更高层抽象，替你做了更多决定）
- 渐进式披露指令：只加载工具摘要，需要时才加载完整说明
- 2026 主流工具：LangChain Deep Agents、Anthropic Agent SDK、OpenAI Agents SDK、Google ADK、Microsoft Agent Framework、CrewAI

**iOS 启示**：
- iOS Agent 应采用渐进式披露策略，减少上下文占用
- MCP 协议应作为工具接口标准
- 防护栏（权限边界）对 iOS 本地安全至关重要

---

### 1.4 HarnessX: A Composable, Adaptive, and Evolvable Agent Harness Foundry (arxiv 2606.14249)

**核心论点**：当前 Harness 手工制作且静态，每个新模型/任务需定制脚手架。HarnessX 提出可组合、自适应、可进化的 Agent Harness 铸造厂，通过替换代数组装类型化 Harness 原语，通过 AEGIS 追踪驱动多智能体进化引擎进行适应。

**关键技术**：
- 替换代数组装类型化 Harness 原语
- AEGIS：追踪驱动多智能体进化引擎，基于符号适应与强化学习的操作镜像
- 闭合 Harness-模型循环：将轨迹转化为 Harness 更新和模型训练信号
- 五个基准测试（ALFWorld, GAIA, WebShop, tau³-Bench, SWE-bench Verified）平均增益 +14.5%（最高 +44.0%）

**iOS 启示**：
- iOS Agent 的 Harness 应支持可组合性，允许动态组装不同原语
- 追踪驱动的进化机制可自动优化 Agent 配置
- 基线越低的场景 Harness 优化收益越大——iOS 本地编程正是基线较低的场景

---

### 1.5 Adaptive Auto-Harness: Sustained Self-Improvement for Agentic System Deployment (arxiv 2606.01770)

**核心论点**：现有自动 Harness 系统（A-Evolve, GEPA, Meta-Harness）在固定离线基准上评估，但真实部署面临开放任务流：历史无限增长、异构任务需不同 Harness、问题分布漂移。单一密集更新的 Harness 会变脆弱，性能先升后降。

**关键技术**：
- 框架分解 oracle Harness 差距为进化损失和适应损失
- 有状态多智能体进化器
- Harness 树 + 解决时路由
- 人类引导钩子（当历史缺乏所需信号时）
- 在预测市场、安全竞赛、事件预测流上优于五个自动 Harness 基线

**iOS 启示**：
- iOS 编程 Agent 面临开放任务流（不同项目、不同语言），需要按任务路由到不同 Harness 配置
- Harness 树结构可实现高效的任务匹配
- 长期使用中需要人类引导机制来弥补自动进化的不足

---

### 1.6 From Model Scaling to System Scaling: Scaling the Harness in Agentic AI (arxiv 2605.26112)

**核心论点**：Agent 性能来自基础模型、记忆基板、上下文构造器、技能路由层、编排循环和验证治理层的交互——这些组成 Agent Harness。未来进展取决于系统设计，而非仅靠更强模型。

**关键技术**：
- 三大瓶颈：上下文治理、可信记忆、动态技能路由
- CheetahClaws：Python 原生参考 Harness
- 提出 Harness 级别基准：轨迹质量、记忆卫生、上下文效率、通信保真度、验证成本、安全演化

**iOS 启示**：
- iOS Agent 需要关注上下文治理（上下文窗口管理）、可信记忆（本地持久化）、动态技能路由（按需加载工具）
- 记忆卫生对长期运行的 iOS Agent 尤为重要——避免上下文污染

---

### 1.7 ProofAgent Harness: Open Infrastructure for Adversarial Evaluation (arxiv 2605.24134)

**核心论点**：AI Agent 进入高风险场景，但评估方法仍以孤立输出为主，遗漏了通过轨迹、压力和对抗交互暴露的失败。ProofAgent Harness 提供可扩展、可审计、对抗性的 AI Agent 评估基础设施。

**关键技术**：
- 对抗多陪审员评分（Adversarial Multi-Juror Scoring）+ 轮次级审计
- 校准陪审员角色、共识检查、轮次级证据
- 发现：小量化本地 Harness LLM 能挑战生产级大 LLM——评估能力来自全 Harness 管线而非模型规模
- 强 Agent 在弱指标、脆弱轮次、不安全重构和操纵路径上选择性失败

**iOS 启示**：
- iOS Agent 评估不能只看最终结果，需要轨迹级审计
- 本地小模型可用于评估/挑战更强的编程模型
- 安全评估应在 iOS 本地进行，不依赖云服务

---

### 1.9 岚天逸见: Harness Engineering 从零理解到动手实践

**核心论点**：Harness Engineering 的核心公式——"读得懂 + 管得住 + 学得会"，即可读性、防御机制、反馈回路三根支柱。关键流程必须有硬约束，不要只靠提示词提醒。

**关键技术**：
- **可读性**：AGENTS.md 项目说明书、渐进式披露（全量灌输不如按需查阅）、分层配置（monorepo 多层 AGENTS.md）
- **防御机制**：状态机锁定执行阶段（RESEARCH→PLAN→EXECUTE→VERIFY）、防"嘴上完成实际上没做"的工具调用验证器、循环失败检测（熔断器思路）、权限边界（代码层拦截）
- **反馈回路**：自动化验证（typecheck+lint+test）、双 Agent 评审（执行者+审查者分离）、错误经验持久化（.harness/lessons-learned.md）

**iOS 启示**：
- iOS Agent 必须实现状态机约束——防止 Agent 直接跳到代码修改阶段
- 硬约束在 iOS 环境中更容易实现（iOS 本身就有权限沙箱机制）
- 错误经验持久化可在本地存储，跨会话改进

---

### 1.10 我没有三颗心脏: AI 写了 100 万行代码

**核心论点**：Harness Engineering 是 Prompt Engineering → Context Engineering → Harness Engineering 演进的第三阶段。OpenAI Codex 团队 7 人 5 个月写 100 万行生产级代码——人类没有手动写过一行代码。核心秘诀不是更强模型，而是 Harness。

**关键技术**：
- 四根支柱：约束（Constrain）→ 告知（Inform）→ 验证（Verify）→ 纠正（Correct）
- 约束：权限控制、操作限制、架构边界（依赖方向固定）
- 告知：AGENTS.md 保持精简、分层配置
- 验证：自动 Lint + 类型检查 + 单元测试 + 构建验证 + 结构测试（验证架构是否合规）
- 纠正：错误信息嵌入修复指引、纠正 Harness 本身（每次 Agent 犯新错就更新系统让此类错误不可能再发生）
- 协同进化原则：模型在后训练阶段纳入特定 Harness——修改工具实现可能导致性能下降

**iOS 启示**：
- iOS Agent 的验证循环天然有优势：Xcode 构建系统、Swift 类型检查、单元测试框架
- 结构测试可验证 iOS 代码架构（如 View/ViewModel 分离）
- Harness 应与模型协同设计，避免紧耦合

---

## 二、Scaffolding 相关

### 2.11 源代码分类学: 编码智能体架构的脚手架分类 (arxiv 2604.03515)

**核心论点**：现有对 LLM 编码智能体的分类停留在抽象能力层面，无法区分架构上根本不同的系统。脚手架代码——控制循环、工具定义、状态管理和上下文策略——才是决定智能体行为的关键因素。

**关键技术**：
- 三层 12 维分类框架：
  - **控制架构**：控制循环类型、循环驱动者、控制流实现
  - **工具与环境接口**：工具集设计、编辑/补丁格式、工具发现策略、上下文检索范式、执行隔离
  - **资源管理**：状态管理、上下文压缩、多模型路由、持久化记忆
- 五种可组合循环原语：ReAct、生成-测试-修复、规划-执行、多次尝试重试、树搜索
- 13 个智能体中 11 个组合使用多种原语
- 控制循环驱动者是最根本的架构区分（用户驱动/脚手架驱动/LLM 驱动）
- 上下文压缩的两种哲学：预防型（结构性限制增长）vs 治疗型（到达阈值时压缩）

**iOS 启示**：
- iOS 编程 Agent 应采用多种循环原语组合（如 ReAct + 生成-测试-修复）
- LLM 驱动模式适合复杂编程任务，但需有脚手架驱动的安全兜底
- 预防型上下文压缩更适合 iOS 本地有限内存环境
- 多模型路由可优化成本——简单任务用小模型，推理用大模型

---

### 2.13 Springer: 认知脚手架的形成性评估

**核心论点**：认知脚手架的"形成性"层面使基于行动者独立利益的评估产生不确定性——许多脚手架不仅辅助认知，更在塑造行动者本身及其利益。评估应转向系统内部控制权的分布。

**关键技术**：
- 概念分析与哲学批判方法
- 互补性论证：脚手架通过功能性差异改变认知任务本身
- 案例：服务化营销塑造顾客利益绑定；数字基础设施创造行动者及其利益
- 评估关键：行动者-脚手架系统内部控制的分布

**iOS 启示**：
- iOS Agent 的脚手架设计会塑造用户的使用习惯和依赖关系
- 应关注控制权在用户、Agent、平台之间的分布
- 避免将用户利益过度绑定于特定服务

---

### 2.14 一文理清 AI Agent：Model、Skill、Scaffold、Harness (博客园)

**核心论点**：Agent = Model + Scaffolding + Harness（精细拆分）。Scaffolding 是模型可见的规则层，Harness 是模型看不见的执行层。社区简化为 Agent = Model + Harness。

**关键技术**：
- Agent 核心概念映射：Model（大脑）、Tool（动作）、Skill（方法包）、Sub-agent（分工）、Scaffolding（模型可见框架）、Harness（执行引擎）、Context Engineering（信息流管理）、Policy（行为策略）
- Skill 两层：说明/触发/使用规则进入 Scaffolding；加载/调度/工具调用/校验依赖 Harness
- Context Engineering 横跨 Scaffolding 和 Harness

**iOS 启示**：
- iOS Agent 设计应明确区分 Scaffolding（模型可见规则，如系统提示词）和 Harness（执行控制）
- Skill 的加载/调度机制需要在 iOS 本地实现
- Policy 应可配置，允许用户调整 Agent 行为偏好

---

### 2.15-2.19 百度/CSDN/腾讯云: AI Agent 核心组件解析

综合这些文章的核心观点：

**核心论点**：Model、Scaffolding、Harness 三层架构是 AI Agent 的"三层骨架"。训练阶段优先强化 Scaffolding，推理阶段重点优化 Harness。

**关键技术**：
- AI-Agent-Node 脚手架实践：三层架构（Agent 编排层 → Skills 组合层 → Tools 原子层）
- 双执行模式：ReAct + Plan+Exec 智能切换（复杂度评估算法加权评分）
- RAG 知识库优化：多格式智能解析、动态检索策略（trim/summarize/vector/hybrid）
- 长期记忆机制：基于 sessionId 用户隔离、记忆持久化到 memory.md、智能注入策略
- 生产级韧性：超时、重试、降级模型、熔断器
- 用户资源隔离：目录隔离、数量限制、存储配额

**iOS 启示**：
- iOS Agent 应实现 ReAct/Plan+Exec 双模式智能切换
- 本地记忆持久化可使用 UserDefaults/CoreData/文件系统
- 生产级韧性设计（超时、重试、熔断）对 iOS 本地稳定性至关重要
- 用户资源隔离在 iOS 沙箱环境中天然具备优势

---

## 三、Prompt Engineering 相关

### 3.20 IBM: 什么是提示工程？

**核心论点**：提示工程的基本原则是好的提示等于好的结果。提示工程减少手动审查和后期编辑的需要。

**关键技术**：
- 核心技术：零样本提示、少样本提示、思维链提示（CoT）
- 提示工程师技能：LLM 工作原理理解、沟通技巧、编程能力（Python）、数据结构和算法
- 最佳实践：清晰简洁、具体指令和示例、迭代细化

---

### 3.21 IBM: 元提示 (Meta-Prompting)

**核心论点**：元提示以自然语言形式为 LLM 提供可重复使用的分步提示模板，使模型能解决整个类别的复杂任务而非仅针对单个问题。它指导 AI 模型"如何思考"而非"思考什么"。

**关键技术**：
- 基于类型论和范畴论：将任务集合映射到结构化提示集合
- 三步骤：确定任务类别(T) → 将任务映射到结构化提示(P) → 执行和输出
- 三种类型：用户提供的元提示、递归元提示(RMP)、指挥模型元提示
- MATH 数据集：零样本元提示 46.3% 准确率 > GPT-4 初始 42.5%

**iOS 启示**：
- iOS Agent 可使用元提示模板处理整个类别的编程任务（如"修复所有编译错误"）
- 递归元提示允许 Agent 自适应调整解题流程
- 指挥模型模式适合多模型协同的 iOS Agent 架构

---

### 3.22 IBM: 思维树 (Tree of Thoughts)

**核心论点**：思维树(ToT)框架模拟人类解决问题的认知策略，使 LLM 能以结构化方式探索多种可能解决方案。相比思维链(CoT)的线性推理，ToT 允许分支、回溯和深入探索。

**关键技术**：
- 四大组件：思维分解、思维生成（采样/提议）、状态评估（值/投票）、搜索算法（BFS/DFS）
- 不确定思维树(TouT)：通过蒙特卡罗 Dropout 量化不确定性
- 优势：同时探索多推理路径、提高复杂问题解决能力
- 限制：计算开销大、实施复杂、搜索效率可能低下

**iOS 启示**：
- iOS Agent 对复杂编程问题可使用 ToT 探索多种解决方案
- 在本地设备上需注意计算开销，可能需要限制搜索深度
- 值评估策略适合代码质量评估（编译通过/测试通过=高值）

---

### 3.23-3.25 IBM: 零样本/单样本/少样本提示

**核心论点**：
- **零样本**：无需示例，依赖预训练知识。优势：简易、灵活；限制：性能变化性大
- **少样本**：提供少量示例指导模型。优势：高效、灵活、提高性能；限制：依赖提示质量、计算复杂
- 关键发现：随着提示结构改进，零样本在某些场景可胜过少样本

**关键技术**：
- 提示四组件：指令、上下文、输入数据、输出指示符
- 少样本可与 RAG 结合进行语义匹配检索示例
- 指令调整和 RLHF 微调改进零样本性能

**iOS 启示**：
- iOS Agent 对常见编程任务可使用少样本提示（内置示例库）
- 对全新任务类型可回退到零样本
- 示例库可在本地存储，按语义相似度检索

---

### 3.26 IBM: 提示工程技术总览

**关键技术**清单：
1. 零样本提示 / 少样本提示
2. 思维链 (CoT) / 思维树 (ToT)
3. 元提示 / 自洽性
4. 生成知识提示 / 提示链
5. 检索增强生成 (RAG)
6. 自动推理和工具使用
7. 自动提示工程师 / 主动提示 / 定向刺激提示
8. 程序辅助语言模型 (PALM)
9. ReAct / Reflexion / 多模态 CoT

**iOS 启示**：
- iOS Agent 应组合使用多种提示技术：CoT 用于推理、ReAct 用于工具调用、Reflexion 用于自我改进
- 提示链适合多步骤编程任务（理解需求→设计方案→编写代码→测试验证）
- RAG 可结合本地文档/代码库进行上下文增强

---

### 3.28 腾讯云: Prompt Engineering 技术

与 IBM 文档内容类似，补充了中文实践视角。核心：提示工程正从手工技巧转向自动化优化。

---

### 3.29 ACL Anthology: EMNLP 2025 Findings

该论文链接未获取到具体内容，跳过。

---

## 四、Context Engineering 相关

### 4.30 A Survey of Context Engineering for LLMs (arxiv 2507.13334)

**核心论点**：Context Engineering 是一门超越简单提示设计的正式学科，系统性优化 LLM 的信息载荷。综述 1400+ 篇论文，建立全面分类法。

**关键技术**：
- 基础组件：上下文检索与生成、上下文处理、上下文管理
- 系统实现：RAG、记忆系统、工具集成推理、多智能体系统
- 关键发现：模型理解复杂上下文的能力强，但生成长文本输出能力弱——存在"基本不对称性"

**iOS 启示**：
- iOS Agent 的上下文管理应系统化设计，而非仅优化提示词
- 模型理解力强但输出受限——iOS Agent 应减少需要长输出的场景
- RAG + 本地记忆系统是 iOS Agent 上下文工程的核心

---

### 4.31 Context Engineering: From Prompts to Corporate Multi-Agent Architecture (arxiv 2603.09619)

**核心论点**：Context Engineering 是独立学科，关注设计、结构化和管理 AI Agent 做决策的整个信息环境。提出五个上下文质量标准：相关性、充分性、隔离性、经济性、溯源。

**关键技术**：
- 上下文质量五标准：relevance, sufficiency, isolation, economy, provenance
- 将上下文框架为 Agent 的"操作系统"
- 高阶学科：意图工程(Intent Engineering) 编码组织目标，规范工程(Specification Engineering) 创建机器可读的策略/标准语料库
- 四层成熟度金字塔：Prompt Engineering → Context Engineering → Intent Engineering → Specification Engineering
- 企业案例：75% 企业计划两年内部署 Agentic AI，但部署潮在扩展复杂性面前反复

**iOS 启示**：
- iOS Agent 应满足五个上下文质量标准——尤其经济性（减少 token 消耗）和隔离性（任务间上下文隔离）
- 规范工程思路可用于编码 iOS 开发规范（Swift 风格指南、Apple HIG 等）为机器可读格式
- 意图工程可帮助 iOS Agent 理解用户的高层编程意图

---

### 4.33 Gartner: Context Engineering

**核心论点**：Context Engineering 正在取代 Prompt Engineering 成为企业 AI 成功的关键。上下文为 AI 增加深度，从黑白漫画变成 3D 虚拟世界。Agentic AI 因对齐不良和协调差而失败率高，Context Engineering 通过策划和共享动态上下文、管理持久上下文来解决。

**关键技术**：
- Gartner 定义：设计和结构化相关数据、工作流和环境，使 AI 系统能理解意图、做出更好决策
- 四大建议：任命 Context Engineering 负责人/团队、设置组织问责制、投资上下文感知架构、制定企业级上下文治理路线图
- 跨模态同步降低失败率
- 持续上下文监控和反馈过程

**iOS 启示**：
- iOS Agent 需要上下文感知架构——整合代码、文档、构建结果等多源数据
- 实时上下文更新（如文件变更通知）对 iOS Agent 尤为重要
- 上下文治理路线图应包含数据源、知识图谱、策略框架和动态记忆管理

---

### 4.34 ACE: Agentic Context Engineering (arxiv 2510.04618)

**核心论点**：ACE 框架将上下文视为可进化的"剧本(playbook)"，通过生成、反思和策展的模块化过程来积累、提炼和组织策略。解决先前方法的简短偏见和上下文坍塌问题。

**关键技术**：
- 上下文作为进化剧本：accumulate → refine → organize
- 模块化过程：generation → reflection → curation
- 防止坍塌：结构化增量更新保留详细知识
- 可利用自然执行反馈进行适应，无需标注监督
- AppWorld 排行榜：ACE 匹配排名第一的生产级 Agent（用更小的开源模型）
- 结果：Agent 基准 +10.6%，金融 +8.6%，显著降低适应延迟和部署成本

**iOS 启示**：
- iOS Agent 的上下文应设计为可进化的剧本，随使用积累经验
- 反思机制允许 Agent 从错误中学习
- 小模型 + 好上下文工程可匹敌大模型——适合 iOS 本地部署

---

### 4.36 The Root Theorem of Context Engineering (arxiv 2604.20874)

**核心论点**：所有维护 LLM 对话的系统都面临两个不可避免的约束：上下文窗口有限、信息质量随累积量退化。从中推导出上下文工程的根定理——**在有界有损信道内最大化信噪比**。

**关键技术**：
- 两个公理：上下文窗口有限、信息质量随累积量退化
- 五个推论：
  1. 质量函数 F(P) 随注入 token 量单调递减
  2. 信号和 token 数量是独立优化变量
  3. 必须有基于保真度阈值触发的门控机制
  4. 稳态持续性（accumulate-compress-rewrite-shed）是唯一可持续架构
  5. 压缩机制在所压缩的信道内运行，需要外部验证门控
- 仅追加系统必然在有限时间内超出有效窗口
- RAG 解决搜索但不解决连续性
- 60+ 会话的持久架构证明稳定记忆足迹

**iOS 启示**：
- iOS Agent 必须实现稳态持续性架构：积累→压缩→重写→丢弃
- 仅追加的上下文策略不可持续——必须有压缩和丢弃机制
- 保真度门控机制可在本地实现：当上下文质量低于阈值时触发压缩
- 信噪比优化是本地 Agent 的核心约束

---

### 4.32/4.35 CSDN: Context Engineering 中文解读

补充中文社区对 Context Engineering 的理解，核心与上述论文一致。强调 Context Engineering 横跨 Scaffolding 和 Harness 两层。

---

### 4.37 ebooks.mpdl.mpg.de: Context Engineering 专著

链接未获取到具体内容，跳过。

---

## 五、Orchestration/Memory/Policy/Skill/Tool/SubAgent/Planner 相关

### 5.38 Adaptation of Agentic AI: Post-Training, Memory, and Skills (arxiv 2512.16301)

**核心论点**：LLM Agent 正在超越提示，向适应性进化。综述后训练、记忆和技能系统，提出四范式框架。

**关键技术**：
- 四范式框架：
  - A1（工具执行信号）：通过监督微调、偏好优化、RL 改进 Agent
  - A2（Agent 输出信号）：用 Agent 输出训练
  - T1（Agent 无关）：提供可复用预训练模块
  - T2（Agent 监督）：用 Agent 输出训练记忆系统、技能库或轻量子 Agent
- 后训练方法、自适应记忆架构、Agent 技能
- 评估实践：深度研究、软件开发、计算机使用、药物发现

**iOS 启示**：
- iOS Agent 适应应结合 A1（基于构建/测试反馈改进）和 T2（用 Agent 输出训练本地记忆/技能库）
- 技能库可本地持久化，跨会话复用
- 后训练方法在 iOS 本地不适用，但在线适应策略可借鉴

---

### 5.39 AI Agent Systems: Architectures, Applications, and Evaluation (arxiv 2601.01743)

**核心论点**：综合 AI Agent 架构——推理、规划、工具调用和环境交互。统一分类法涵盖 Agent 组件、编排模式和部署设置。

**关键技术**：
- Agent 组件：策略/LLM 核心、记忆、世界模型、规划器、工具路由器、评估器
- 编排模式：单 Agent vs 多 Agent；集中式 vs 分散式协调
- 关键权衡：延迟 vs 准确性、自主性 vs 可控性、能力 vs 可靠性
- 评估挑战：非确定性、长视野信用分配、工具和环境可变性、隐藏成本（重试和上下文增长）

**iOS 启示**：
- iOS 编程 Agent 倾向于单 Agent 架构（减少延迟和复杂性）
- 可靠性 > 自主性：iOS 环境对可靠性要求极高
- 评估应关注隐藏成本（重试次数、上下文增长）

---

### 5.41 A Comprehensive Survey on Agent Skills (arxiv 2605.07358)

**核心论点**：Agent 从头推理和低级工具调用变得越来越低效、易错、难维护。Agent 技能是可复用的程序化产物，协调工具、记忆和运行时上下文。

**关键技术**：
- Agent 技能生命周期四阶段：表示(Representation) → 获取(Acquisition) → 检索(Retrieval) → 进化(Evolution)
- Agent 处理高层推理和规划，技能形成可靠、可复用、可组合的执行层
- 开放挑战：质量控制、互操作性、安全更新、长期能力管理

**iOS 启示**：
- iOS Agent 应构建技能生命周期管理：本地存储技能表示、从执行中获取技能、按需检索、随使用进化
- 技能可表示为结构化模板（如"修复 Swift 编译错误"技能 = 检索错误 → 定位文件 → 修改代码 → 验证构建）
- 互操作性：技能应跨项目可复用

---

### 5.42 Externalization in LLM Agents (arxiv 2604.08224)

**核心论点**：LLM Agent 的构建越来越不依赖修改模型权重，而是重组模型周围的运行时。能力外部化——记忆外部化状态、技能外部化过程专长、协议外部化交互结构、Harness 工程统一协调——是核心趋势。

**关键技术**：
- 认知人工制品视角：Agent 基础设施的重要性不仅在于添加辅助组件，更在于将困难认知负担转化为模型能更可靠解决的形式
- 三种外部化形式：记忆（跨时间外部化状态）、技能（外部化过程专长）、协议（外部化交互结构）
- Harness 工程作为统一层协调外部化模块
- 历史演进：权重 → 上下文 → Harness
- 新兴方向：自进化 Harness、共享 Agent 基础设施

**iOS 启示**：
- iOS Agent 的核心架构决策：什么能力外部化（存本地）vs 什么留在模型权重中
- 记忆外部化：Swift 代码上下文、项目结构、构建历史
- 技能外部化：编程模式、调试流程、重构策略
- 协议外部化：与 Xcode/LLDB/Swift Package Manager 的交互协议

---

### 5.43-5.45 其他编排与规划论文

- **arxiv 2603.07670**: AI Agent 系统综述（架构、应用、评估），与 #39 主题类似
- **arxiv 2605.06716**: 论文获取受限，跳过
- **arxiv 2604.02369**: 论文获取受限，跳过

---

### 5.46 ZenML: LLM 编排框架比较

**核心论点**：比较主流 LLM 编排框架的特性和适用场景。

**关键技术**：
- LangGraph: 基于图的状态机编排
- CrewAI: 基于角色的多 Agent 架构
- AutoGen: 对话驱动编排
- Temporal: 持久执行平台
- 核心问题：何时用框架 vs 何时自建

**iOS 启示**：
- iOS Agent 编排应倾向于轻量自建，而非引入重型框架
- 状态机模式适合 iOS 本地编程 Agent

---

### 5.48 Rethinking Memory in LLM Agents (arxiv 2505.00675)

**核心论点**：记忆对 LLM Agent 至关重要，但现有综述偏重应用层，忽略原子操作。将记忆分为参数化（模型权重内隐式）和上下文（外部显式数据），定义六种核心操作。

**关键技术**：
- 六种核心记忆操作：巩固(Consolidation)、更新(Updating)、索引(Indexing)、遗忘(Forgetting)、检索(Retrieval)、浓缩(Condensation)
- 四个关键研究主题：长期记忆、长上下文、参数化修改、多源记忆
- 记忆表示：结构化/非结构化上下文记忆

**iOS 启示**：
- iOS Agent 应实现完整的六种记忆操作
- 遗忘机制对本地存储管理尤其重要——避免无限增长
- 浓缩操作可减少上下文窗口压力
- 多源记忆（代码库、文档、构建日志）需统一检索接口

---

### 5.50 Sub-Agent 模式增强安全性

**核心论点**：子 Agent 模式（进程隔离/最小权限委派）通过将单体 Agent 分解为轻量级、单一用途的子 Agent 层次结构，每个沙箱化且仅具最少工具、记忆和网络访问，直接缓解对抗性提示注入、不受控文件系统/工具效应和过度宽松的代码执行风险。

**iOS 启示**：
- iOS Agent 可用子 Agent 模式增强安全性——不同功能的子 Agent 有不同权限
- 例如：代码生成子 Agent 无网络权限，文档查询子 Agent 无文件写入权限

---

### 5.51-5.52 边缘智能/移动端 Agent 论文

- **Semantic Scholar 60dbb197**: Toward Edge General Intelligence——边缘通用智能方向，与 iOS 本地 Agent 直接相关
- **Springer 10.1007/s44336-025-00024-x**: 移动端 AI Agent 研究

**iOS 启示**：
- 边缘智能是 iOS 本地 Agent 的直接学术支撑
- 模型压缩、量化、端侧推理是关键技术方向

---

### 5.53-5.57 其他编排/RL/规划论文

- **OR-LLM-Agent**: 用 LLM Agent 自动化运筹优化问题的建模和求解
- **arxiv 2512.11143**: 论文获取受限
- **arxiv 2502.10931**: 论文获取受限
- **arxiv 2502.01390**: 论文获取受限
- **arxiv 2510.04023**: 论文获取受限

---

## 六、CSDN 补充链接

### 6.58-6.63 CSDN/新浪/期刊

- **#58**: CSDN 博客内容较旧（2024年初），与当前 Agent 架构相关性弱
- **#59**: CSDN 博客，Agent 基础概念，与 #14 等文章内容重叠
- **#60**: CSDN 博客，AI Agent 概述，内容较早期
- **#61**: CSDN 博客，关于 LLM 编程助手的技术分析
- **#62**: 新浪财经：2026 年 AI Agent 行业动态
- **#63**: 计算机工程与应用期刊：Agent 技术综述

---

## 七、综合分析与 iOS 本地编程智能体设计启示

### 7.1 核心架构公式

基于所有文献的共识：

```
Agent = Model + Scaffolding + Harness
```

其中：
- **Model**: 本地运行的 LLM（量化后的端侧模型或云端 API）
- **Scaffolding**: 模型可见的规则层（系统提示词、工具描述、AGENTS.md、输出格式、代码规范）
- **Harness**: 模型不可见的执行层（编排循环、工具执行、状态管理、验证循环、权限控制）

### 7.2 iOS 本地编程 Agent 的核心设计决策

| 决策维度 | 推荐选择 | 依据 |
|----------|---------|------|
| 控制模式 | LLM 驱动 + 脚手架安全兜底 | #11 分类学研究 |
| 循环原语 | ReAct + 生成-测试-修复 | #11, Claude Code 实践 |
| 上下文管理 | 稳态持续性（accumulate-compress-rewrite-shed） | #4.36 Root Theorem |
| 上下文压缩 | 预防型（结构性限制增长）+ 治疗型（到达阈值时压缩） | #11 分类学 |
| 记忆架构 | 三级：轻量级索引（始终加载）→ 按需拉取的详细信息 → 仅搜索访问的原始记录 | Claude Code 实践 |
| 技能管理 | 生命周期四阶段：表示→获取→检索→进化 | #5.41 |
| 安全架构 | 子 Agent 模式（最小权限委派）| #5.50 |
| 验证循环 | 构建验证 + 类型检查 + 单元测试 + 结构测试 | #1.10 OpenAI Codex |
| 上下文质量 | 相关性、充分性、隔离性、经济性、溯源 | #4.31 |
| 多模型路由 | 简单任务用小模型，推理用大模型 | #11 |

### 7.3 Harness 工程三支柱在 iOS 上的实现

1. **可读性（读得懂）**：
   - AGENTS.md / PROJECT.md 项目配置文件
   - 渐进式披露工具说明（只加载当前步骤所需工具）
   - 分层配置（项目级 + 模块级规则）

2. **防御机制（管得住）**：
   - 状态机约束（RESEARCH → PLAN → EXECUTE → VERIFY）
   - iOS 沙箱权限作为硬约束
   - 熔断器（连续失败 N 次后强制停止）
   - 验证守卫（改代码后必须跑构建/测试）

3. **反馈回路（学得会）**：
   - 自动验证循环（typecheck + lint + test）
   - 双 Agent 评审（执行者+审查者）
   - 错误经验持久化（lessons-learned.md）
   - ACE 式上下文进化（从执行反馈中学习）

### 7.4 工程优先级建议

基于文献证据，iOS 本地编程智能体的工程优先级排序：

1. **验证循环**（最高优先）——"给模型一种验证自身工作的手段，能将质量提升 2-3 倍"（Boris Cherny, Claude Code）
2. **上下文管理**（核心瓶颈）——信噪比优化、稳态持续性架构
3. **防御机制**（安全底线）——状态机约束、权限边界、熔断器
4. **技能/记忆系统**（长期价值）——可复用技能库、分层记忆
5. **多模型路由**（成本优化）——简单任务小模型、推理大模型
6. **自适应进化**（远期方向）——Harness 自动优化、上下文自动进化

---

## 附录：无法访问的链接

| # | 链接 | 状态 |
|---|------|------|
| 1 | https://picrew.github.io/LLM-Harness/main.pdf | PDF 二进制流无法解析 |
| 8 | https://blog.51cto.com/u/16976/14943730 | 文章不存在或已删除 |
| 12 | https://browse-export.arxiv.org/abs/2606.14674 | 速率限制 |
| 29 | https://aclanthology.org/2025.findings-emnlp.1155.pdf | 未获取 |
| 37 | https://ebooks.mpdl.mpg.de/ebooks/Record/EB002372860 | 未获取 |
| 43 | https://ar5iv.labs.arxiv.org/html/2603.07670 | 未详细获取 |
| 44 | https://export.arxiv.org/pdf/2605.06716 | 未获取 |
| 45 | https://ar5iv.labs.arxiv.org/html/2604.02369 | 未获取 |
| 47 | https://dl.acm.org/doi/10.1145/3748302 | 未获取 |
| 51 | https://www.semanticscholar.org/paper/... | 未详细获取 |
| 52 | https://link.springer.com/article/10.1007/s44336-025-00024-x | 未详细获取 |
| 54 | https://ar5iv.labs.arxiv.org/html/2512.11143 | 未获取 |
| 55 | https://export.arxiv.org/pdf/2502.10931 | 未获取 |
| 56 | https://ar5iv.labs.arxiv.org/html/2502.01390 | 未获取 |
| 57 | https://ar5iv.labs.arxiv.org/html/2510.04023 | 未获取 |
| 58-63 | CSDN/新浪/期刊链接 | 内容较旧或与核心主题关联弱 |
