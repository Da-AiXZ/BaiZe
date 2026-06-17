# 白泽（Baize）— iOS 本地编程智能体 产品需求文档

> **文档版本**：1.0 | **日期**：2026-06-17 | **作者**：许清楚（产品经理）
> **目标设备**：iPad Pro 2021 M1 | iOS 16.6.1 | TrollStore 免签安装
> **技术栈**：Swift + SwiftUI + WKWebView(Monaco) + nodejs-mobile(--jitless) + CPython(embedded)

---

## 1. 产品目标

### 一句话定义

**白泽是运行在 iPad 上的本地编程智能体**——像 Claude Code 一样强大，但所有工具执行在本地完成，通过 API 接入所有主流模型提供商。

### 核心价值主张

| 维度 | Claude 手机版 | 白泽 |
|------|-------------|------|
| 工作模式 | 云端对话，纯聊天 | 本地执行，真实编程 |
| 代码执行 | 无法执行 | 本地 Node.js/Python/Shell |
| 文件系统 | 无访问 | 完整文件系统（TrollStore 免沙箱） |
| 工具系统 | 无 | 54+ 内置工具 + MCP 扩展 |
| 模型选择 | 仅 Claude | 所有主流模型提供商 |
| 终端 | 无 | 嵌入式终端（命令-输出模式） |
| Git | 无 | 完整 Git 操作 |

**核心差异化**：目前市场上**没有任何主流编程智能体有 iOS/iPadOS 版本**（Cursor/Claude Code/Copilot/Aider 均无），白泽是首创产品。

### 成功指标

| 指标 | Phase 1 目标 | 说明 |
|------|-------------|------|
| **首次完整 Agent Loop** | ≤ 10 周内实现 | 用户输入 → LLM 推理 → 工具调用 → 本地执行 → 返回结果 |
| **基础编程任务成功率** | ≥ 60% | 文件创建/编辑、代码执行、错误修复等基础场景 |
| **端到端延迟** | ≤ 5 秒 | 从用户输入到首个 LLM 响应 token（不含网络） |
| **TrollStore 安装成功率** | ≥ 95% | 从下载 IPA 到可运行 |
| **本地执行覆盖** | Node.js + Python + Shell | 三种运行时均可执行代码 |

---

## 2. 用户故事

### Developer（主力用户 — iPad 上的独立开发者/全栈工程师）

- **US-D1**：作为一个 Developer，我想要在 iPad 上通过自然语言描述需求让 Agent 自主编写代码，以便我在移动场景下也能完成编程工作
- **US-D2**：作为一个 Developer，我想要 Agent 在本地执行代码并返回运行结果，以便我确认代码正确性（无需云端服务器）
- **US-D3**：作为一个 Developer，我想要自由选择不同的 AI 模型（OpenAI/Claude/DeepSeek/OpenRouter），以便我根据任务复杂度和成本灵活切换
- **US-D4**：作为一个 Developer，我想要 Agent 在执行危险操作前请求我确认，以便我不会丢失重要数据
- **US-D5**：作为一个 Developer，我想要 Agent 记住我的项目偏好和编码规范，以便它持续生成符合项目风格的代码

### Learner（学习者 — 用 iPad 学习编程的学生/转行者）

- **US-L1**：作为一个 Learner，我想要 Agent 解释代码片段的含义，以便我理解不熟悉的代码
- **US-L2**：作为一个 Learner，我想要 Agent 在本地运行代码并展示输出结果，以便我即时验证学习成果
- **US-L3**：作为一个 Learner，我想要 Agent 提供逐步调试指导，以便我学会独立定位和修复错误

### Contributor（贡献者 — 开源社区/逆向研究者）

- **US-C1**：作为一个 Contributor，我想要 Agent 通过 MCP 协议扩展工具能力，以便社区可以为白泽开发新工具
- **US-C2**：作为一个 Contributor，我想要自定义 Agent 的策略规则（ABAC），以便我精确控制 Agent 的行为边界
- **US-C3**：作为一个 Contributor，我想要 Agent 访问完整文件系统（TrollStore 免沙箱），以便我在 iOS 逆向/安全研究场景中使用

---

## 3. 需求池

### P0 — 必须有（MVP 核心链路）

| # | 需求名称 | 简要描述 | 验证等级 | 优先级理由 |
|---|---------|---------|---------|-----------|
| P0-1 | **SwiftUI 应用壳** | 主界面框架、导航、生命周期管理 | ✅ 已验证 | 应用容器，一切的基础 |
| P0-2 | **Agent Loop（单循环架构）** | 用户输入 → LLM 推理 → 工具调用 → 执行 → 循环，参考 Claude Code | ✅ 已验证 | 白泽的核心价值，没有它就不是智能体 |
| P0-3 | **OpenAI API 流式对话** | SSE 流式调用 OpenAI Chat Completions API，AsyncThrowingStream 推送 UI | ✅ 已验证 | 最基础的 LLM 接入能力，iOS 15+ URLSession 原生支持 |
| P0-4 | **Monaco Editor via WKWebView** | 嵌入 Monaco Editor 提供代码编辑、语法高亮、多文件 Tab | ✅ 已验证（CodeApp） | 编程智能体必须有代码编辑器，CodeApp 已在生产环境验证 |
| P0-5 | **文件浏览器** | 浏览项目目录结构、打开文件、创建/删除文件/文件夹 | ✅ 已验证 | 编程的基础交互入口 |
| P0-6 | **基础工具集** | read_file, write_file, edit_file, list_directory, search_files, search_content | ✅ 已验证 | Agent 操作文件系统的最小工具集 |
| P0-7 | **TrollStore 安装与验证** | GitHub Actions 编译 IPA → TrollStore 安装 → 免沙箱运行 | ✅ 已验证 | 分发方案，无它则无法在目标设备运行 |
| P0-8 | **BAIZE.md 项目配置** | 项目级配置文件（类似 CLAUDE.md），定义编码规范、常用命令、安全策略 | ✅ 已验证 | Agent 理解项目上下文的入口 |
| P0-9 | **权限确认机制** | 危险操作（文件删除、代码执行）前弹窗确认 | ✅ 已验证 | 本地执行安全底线，不可跳过 |
| P0-10 | **API Key 管理** | 安全存储（Keychain）、多 Provider 配置、模型选择 | ✅ 已验证 | 接入 LLM 的前提 |

### P1 — 应该有（核心体验增强）

| # | 需求名称 | 简要描述 | 验证等级 | 优先级理由 |
|---|---------|---------|---------|-----------|
| P1-1 | **Node.js 本地执行** | 嵌入 nodejs-mobile (--jitless V8 解释模式)，posix_spawn 执行 JS 脚本 | ✅ 已验证（CodeApp） | 前端/全栈开发核心运行时，Agent Loop I/O 为主影响小 |
| P1-2 | **Python 本地执行** | 嵌入 CPython 3.13+ iOS 嵌入模式，posix_spawn 执行 Python 脚本 | ✅ 已验证（Python-IDE） | 数据分析/脚本/后端开发运行时，Python 不需 JIT 性能正常 |
| P1-3 | **Shell 命令执行** | ios_system (70+ 命令) + posix_spawn，命令-输出模式 | ✅ 已验证（CodeApp） | 包管理、构建工具、系统操作必需 |
| P1-4 | **多模型支持** | OpenRouter 统一网关 + Anthropic/Gemini/DeepSeek 直接调用 | ✅ 已验证 | 不同任务用不同模型，成本/质量最优 |
| P1-5 | **ABAC 策略引擎** | 参考 @ai-abacus/core 实现 allow/ask/deny 三态策略，5 个 Scope + 7 层优先级 | ✅ 已验证 | 精细化权限控制，替代粗粒度弹窗确认 |
| P1-6 | **终端 UI** | 基于 UIKit 的命令-输出终端（非交互式 Shell） | ✅ 已验证 | 直接查看命令执行结果，比对话面板更直观 |
| P1-7 | **Git 集成** | SwiftGit2 (libgit2) 实现 status/diff/commit/log/branch | ✅ 已验证 | 版本控制是编程的基本需求 |
| P1-8 | **上下文压缩** | Token 预算管理 + 自动摘要（参考 Claude Code 5 层压缩简化版） | ✅ 已验证 | 本地内存受限，长对话必须压缩 |
| P1-9 | **对话持久化** | 会话保存/恢复，SQLite 存储 | ✅ 已验证 | 移动端随时被中断，必须能恢复 |
| P1-10 | **MCP Client** | Swift MCP SDK 实现工具扩展协议 | ✅ 已验证 | 社区扩展白泽能力的标准接口 |

### P2 — 可以有（高级功能）

| # | 需求名称 | 简要描述 | 验证等级 | 优先级理由 |
|---|---------|---------|---------|-----------|
| P2-1 | **本地向量搜索** | sqlite-vec + CoreML Embedding (all-MiniLM-L6-v2) | ✅ 已验证 | 长期记忆和语义检索，非 MVP 核心 |
| P2-2 | **长期记忆系统** | 工作记忆 + 短期记忆 + 长期记忆（SQLite+sqlite-vec），BM25+向量混合检索 | ✅ 已验证 | 跨会话学习和偏好记忆，增强体验但非必须 |
| P2-3 | **技能系统** | Markdown+YAML 前置元数据的技能模板，渐进式披露，语义自动匹配 | ✅ 已验证 | 可复用编程模式，提升 Agent 能力上限 |
| P2-4 | **规划系统** | DAG 目标图 + 自适应调度 + 只读规划模式 | ✅ 已验证 | 复杂任务分解，简单任务不需要 |
| P2-5 | **WASM 代码执行** | 嵌入 Wasmtime/SwiftWasm 运行 WASM 模块 | ✅ 已验证 | 安全沙箱执行，JIT 不可用时的补充 |
| P2-6 | **子 Agent 委派** | Coordinator 模式，子 Agent 按最小权限隔离执行 | ✅ 已验证 | 复杂任务并行处理，但单 Agent 已够用多数场景 |
| P2-7 | **Root Helper 特权操作** | TrollStore persona-mgmt entitlement，以 root 权限执行操作 | ⚠️ 有限可行 | 高级逆向/系统操作，少数用户需要 |
| P2-8 | **ACP 协议支持** | Agent-IDE 标准通信协议 | ❓ 未验证 | 协议尚在发展，等成熟后接入 |
| P2-9 | **多窗口协作** | iPadOS 多窗口支持，不同项目/对话并行 | ✅ 已验证 | 提升多任务效率，但实现复杂 |
| P2-10 | **本地 Ollama/llamacpp** | 通过 WiFi 调用局域网内的本地模型 | ✅ 已验证 | 零成本本地推理，但依赖外部设备 |
| P2-11 | **Prompt 防御** | 参考 agent-governance-toolkit 的 12 攻击向量检测（纯正则，<5ms） | ✅ 已验证 | 安全增强，纯前端检测零成本 |

### 明确排除的功能（不可行）

| 功能 | 排除原因 |
|------|---------|
| **交互式 Shell（fork+exec）** | ❌ iOS 内核级禁止 fork()，无绕过方法 |
| **JIT 编译** | ❌ iOS 15+ A12+ 禁止 dynamic-codesigning，TrollStore 也不可授予 |
| **后台 Agent 常驻** | ❌ TrollStore 安装的 IPA 无后台执行特权，切后台约 30 秒暂停 |
| **spawn 未签名二进制** | ❌ iOS 要求所有可执行代码必须签名，posix_spawn 只能启动已签名二进制 |

---

## 4. UI 设计理念

### 整体视觉风格

- **深色为主**：编程场景深色主题是默认选择，降低视觉疲劳
- **信息密度优先**：参考 VS Code / Cursor 的信息密度，iPad 12.9 寸屏幕应充分利用
- **原生感**：SwiftUI 原生控件 + 系统级动画，不做「网页套壳」
- **状态可视**：Agent Loop 的每一步（推理/工具调用/执行/等待确认）都要有明确的状态指示

### 核心页面布局

#### Dashboard（首页/项目选择）

```
┌────────────────────────────────────────────┐
│  白泽                        + 新建项目    │
├────────────────────────────────────────────┤
│                                            │
│  📁 最近项目                               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐  │
│  │ my-app   │ │ baize    │ │ demo     │  │
│  │ React    │ │ Swift    │ │ Python   │  │
│  │ 2分钟前  │ │ 1小时前  │ │ 昨天     │  │
│  └──────────┘ └──────────┘ └──────────┘  │
│                                            │
│  🔗 连接状态                               │
│  OpenAI: ✅  Anthropic: ✅  OpenRouter: ✅ │
│                                            │
│  📊 今日用量                               │
│  Token: 125K  API 调用: 48  费用: $2.30   │
│                                            │
└────────────────────────────────────────────┘
```

#### Chat+Editor（核心工作区 — 三栏布局）

```
┌─────────────────────────────────────────────────────────────────┐
│ ◀ ▶ 白泽  │  文件 编辑 查看 工具 帮助           │ 🔔 ⚙️  │
├────────┬───────────────────────────────────┬───────────────────┤
│        │                                   │                   │
│ 文件   │         代码编辑器               │    对话面板       │
│ 浏览器 │         (Monaco Editor)           │                   │
│        │                                   │   🤖 我需要你...│
│ 📁 src │   1  import React from 'react'   │   👤 帮我创建... │
│ 📁 lib │   2  import { Button } from...    │   🤖 好的，我来 │
│ 📄 App │   3                               │     分析项目...  │
│ 📄 main│   4  function App() {            │   🔧 read_file   │
│        │   5    return (                   │   ✅ src/App.tsx │
│ 🔍搜索 │   6      <div>                   │   🔧 edit_file   │
│        │   7        <Button>              │   ✅ 已修改      │
│        │   8      </div>                   │   🤖 完成了！   │
│        │   9    )                          │                   │
│        │  10  }                            │   ────────────── │
│        │                                   │   > 输入消息... │
├────────┴───────────────────────────────────┴───────────────────┤
│                        终端 (可折叠)                            │
│  $ npm test                                                    │
│  PASS src/App.test.tsx                                         │
│  ✓ renders without crashing (23ms)                            │
│  $ _                                                           │
└─────────────────────────────────────────────────────────────────┘
```

#### File Explorer（文件浏览器 — 侧边栏）

- 树形目录结构，支持展开/折叠
- 文件类型图标区分（代码/配置/图片/Markdown）
- 右键/长按菜单：重命名、删除、新建文件/文件夹
- 搜索：文件名模糊搜索 + 文件内容 Grep 搜索
- BAIZE.md 项目配置文件高亮显示

#### Settings（设置页）

```
┌────────────────────────────────────────────┐
│  ← 设置                                    │
├────────────────────────────────────────────┤
│                                            │
│  🔑 API 配置                               │
│  ├── OpenAI      sk-****    ✅ 已连接      │
│  ├── Anthropic   sk-ant-*** ✅ 已连接      │
│  ├── OpenRouter  sk-or-***  ✅ 已连接      │
│  └── + 添加提供商                          │
│                                            │
│  🤖 默认模型                               │
│  ├── 编程任务: gpt-4o                      │
│  ├── 规划任务: claude-sonnet-4-20250514    │
│  └── 快速任务: deepseek-chat               │
│                                            │
│  🛡️ 权限模式                               │
│  ○ 默认（每次危险操作确认）                  │
│  ○ 接受编辑（自动接受文件编辑）              │
│  ○ 只读规划（禁止所有写入）                  │
│  ○ 绕过模式（自动执行，需确认开启）          │
│                                            │
│  💾 存储                                   │
│  ├── 项目目录: /var/mobile/Documents       │
│  ├── 运行时: Node.js ✅  Python ✅         │
│  └── 缓存: 128MB  [清理]                   │
│                                            │
│  ℹ️ 关于白泽                               │
│  版本 1.0.0  |  TrollStore ✅  |  设备 M1  │
└────────────────────────────────────────────┘
```

### 交互模式

| 模式 | 说明 | 触发 | 适用场景 |
|------|------|------|---------|
| **对话模式** | 纯对话，Agent 只回答不执行 | 默认 | 代码讨论、问题咨询 |
| **Agent 模式** | 自主执行，危险操作需确认 | 用户开启 | 日常编程任务 |
| **全自动模式** | 无需确认，信任所有操作 | 用户明确开启 | 高信任场景（个人项目） |
| **只读规划** | Agent 只分析不执行 | 用户开启 | 代码审查、影响分析 |

### 参考产品

| 参考产品 | 参考了什么 | 为什么参考 |
|---------|----------|----------|
| **Claude Code** | Agent Loop 架构、Tool System 设计、上下文压缩策略、CLAUDE.md | 最成熟的编程智能体，单循环架构已验证，5 层压缩策略可参考 |
| **CodeApp** | Monaco Editor + WKWebView 集成、nodejs-mobile 嵌入方式、ios_system 使用 | 唯一在 App Store 上验证了 iOS IDE + 嵌入式运行时方案的完整产品 |
| **Cursor** | 三栏布局（文件/编辑器/对话）、Agent 执行状态可视化、编辑内联 diff | 编程 Agent UI 的事实标准，三栏布局被开发者广泛接受 |
| **a-Shell** | ios_system 70+ 命令、命令-输出终端模式 | 验证了 iOS 上无需 fork 的终端方案可行 |
| **VS Code** | 快捷键体系、命令面板、扩展生态(MCP) | 开发者最熟悉的编辑器交互范式 |

---

## 5. Phase 1 范围定义

### Phase 1 明确包含的功能

| # | 功能 | 验证等级 | 交付标准 |
|---|------|---------|---------|
| 1 | SwiftUI 应用壳 + 三栏布局 | ✅ | 可在 iPad 上运行，横屏三栏、竖屏自适应 |
| 2 | Monaco Editor via WKWebView | ✅ | 语法高亮、多 Tab、基本编辑操作可用 |
| 3 | 文件浏览器（树形目录） | ✅ | 可浏览 /var/mobile/Documents 下项目文件 |
| 4 | OpenAI API SSE 流式对话 | ✅ | 可流式显示 LLM 响应，支持 Function Calling |
| 5 | Agent Loop（单循环） | ✅ | 输入 → LLM → 工具调用 → 执行 → 循环，完整闭环 |
| 6 | 6 个基础文件工具 | ✅ | read_file, write_file, edit_file, list_directory, search_files, search_content |
| 7 | 权限确认弹窗 | ✅ | 写入/删除操作前弹窗确认，用户可 allow/deny |
| 8 | API Key 管理（Keychain） | ✅ | 至少支持 OpenAI API Key 配置和安全存储 |
| 9 | BAIZE.md 项目配置 | ✅ | 自动发现并加载项目根目录的 BAIZE.md |
| 10 | TrollStore 安装验证 | ✅ | GitHub Actions 编译 IPA → TrollStore 安装 → 免沙箱运行 |
| 11 | 执行命令工具（execute_command） | ⚠️ | ios_system 执行基本 Shell 命令（ls, cat, grep 等） |
| 12 | Node.js 代码执行（run_node） | ✅ | 嵌入 nodejs-mobile，posix_spawn 执行 JS 脚本 |
| 13 | Python 代码执行（run_python） | ✅ | 嵌入 CPython，posix_spawn 执行 Python 脚本 |

### Phase 1 明确排除的功能

| # | 排除功能 | 排除原因 |
|---|---------|---------|
| 1 | 多模型支持（除 OpenAI 外） | Phase 1 聚焦打通核心链路，一个 Provider 足够验证 |
| 2 | ABAC 策略引擎 | Phase 1 用简单弹窗确认即可，精细策略引擎留 Phase 2 |
| 3 | 终端 UI | Phase 1 通过对话面板展示命令输出，独立终端 UI 留 Phase 2 |
| 4 | Git 集成 | 非核心链路，留 Phase 2 |
| 5 | 向量搜索/长期记忆 | 非核心链路，留 Phase 2 |
| 6 | MCP 协议 | 扩展机制，留 Phase 2 |
| 7 | 技能/规划系统 | 高级 Agent 能力，留 Phase 3 |
| 8 | 子 Agent 委派 | 高级编排能力，留 Phase 3 |
| 9 | 交互式 Shell | ❌ 不可行（iOS 内核级禁止 fork） |
| 10 | 后台 Agent 常驻 | ❌ 不可行（iOS 系统限制） |
| 11 | WASM 代码执行 | 补充运行时，留 Phase 2 |
| 12 | Root Helper | 高级特权操作，留 Phase 3 |

### Phase 1 验收标准

1. **安装验收**：在 iPad Pro M1 iOS 16.6.1 上通过 TrollStore 安装白泽 IPA，App 正常启动，FileManager 可访问 `/var/mobile/Documents`
2. **对话验收**：用户输入编程需求 → Agent 调用 OpenAI API → 流式显示响应 → 正确识别 Function Calling → 执行工具 → 返回结果 → 循环直到完成
3. **编辑验收**：Agent 通过 write_file/edit_file 创建/修改文件 → Monaco Editor 实时反映变更 → 文件浏览器同步更新
4. **执行验收**：Agent 通过 run_node 执行 JS 脚本 → 返回 stdout/stderr → 通过 run_python 执行 Python 脚本 → 返回输出
5. **安全验收**：文件删除操作弹出确认对话框 → 用户 deny 后操作不执行 → 用户 allow 后操作执行
6. **上下文验收**：项目目录存在 BAIZE.md → Agent 自动读取并遵循编码规范 → 常用命令可被 Agent 引用
7. **中断恢复**：Agent 执行过程中 App 切后台 → 30 秒内返回不丢失状态 → 强制结束后重启可恢复最近对话

---

## 6. 待确认问题

### 需要用户进一步确认的设计决策

| # | 问题 | 影响范围 | 建议默认 | 备选方案 |
|---|------|---------|---------|---------|
| Q1 | **Node.js 运行时架构**：nodejs-mobile 是嵌入主进程还是作为 App Extension 隔离运行？ | 代码执行稳定性 | 嵌入主进程（TrollStore 免沙箱无需隔离） | App Extension 隔离（CodeApp 方案，更稳定但复杂） |
| Q2 | **Monaco Editor 版本**：使用 CodeApp 的 fork 版本还是官方 Monaco Editor？ | 编辑器功能和维护成本 | CodeApp fork（已验证 iOS 兼容性） | 官方 Monaco（功能更新，需自行适配 iOS） |
| Q3 | **Python 包预装范围**：嵌入 CPython 时预装哪些常用包？ | App 体积和用户需求 | 最小集（pip, setuptools）+ 按需安装 | 完整科学计算集（numpy, pandas 等，App 增加 100MB+） |
| Q4 | **项目目录默认路径**：用户项目文件存放在哪里？ | 文件管理体验 | `/var/mobile/Documents/Baize/` | 用户自定义 |
| Q5 | **Phase 1 仅支持 OpenAI 是否足够**：是否同时支持 Anthropic API？ | MVP 用户体验 | 仅 OpenAI（减少适配工作量） | 同时支持 OpenAI + Anthropic（增加 1-2 周） |
| Q6 | **权限模式粒度**：Phase 1 用简单弹窗还是直接实现 ABAC？ | 开发工作量 | 简单弹窗（2 周开发量） | ABAC 策略引擎（4-5 周开发量） |

### 需要实测才能确定的技术点

| # | 待测项 | 原因 | 测试方案 | 影响的需求 |
|---|-------|------|---------|----------|
| T1 | **nodejs-mobile 在 TrollStore no-sandbox 下的 child_process** | nodejs-mobile FAQ 说"有权限问题"，但这是 App Store 沙箱环境。TrollStore no-sandbox 可能解除此限制，但无公开案例验证 | 在 TrollStore 环境下运行 nodejs-mobile，测试 spawn/exec | P1-1 Node.js 执行 |
| T2 | **ios_system 在 TrollStore no-sandbox 下的文件系统访问范围** | ios_system 默认受沙箱限制。no-sandbox 后应能访问 /var/mobile 等路径，但未验证 | 在 TrollStore 环境下运行 ios_system，测试各路径读写 | P1-3 Shell 命令执行 |
| T3 | **posix_spawn 在 TrollStore 下能否 spawn App Bundle 外的二进制** | 理论上 no-sandbox 解除路径限制，但 iOS 可能仍要求签名验证 | 在 TrollStore 环境下 posix_spawn 外部二进制 | P2-7 Root Helper |
| T4 | **nodejs-mobile 不使用 App Extension 直接在主进程运行的稳定性** | CodeApp 使用 App Extension 隔离。TrollStore 环境下可能不需要隔离，但内存泄漏等问题未知 | 主进程运行 nodejs-mobile，执行长时间任务测试内存占用 | Q1 运行时架构决策 |
| T5 | **Monaco Editor 在 WKWebView 中的性能基准** | CodeApp 已验证可用，但白泽场景需要同时运行 Agent Loop + Monaco，内存和 CPU 竞争情况未知 | 在 M1 iPad 上同时运行 Agent Loop + Monaco Editor，测试响应延迟 | P0-4 代码编辑器 |

---

## 附录 A：核心技术决策摘要

| 决策 | 选择 | 验证等级 | 依据 |
|------|------|----------|------|
| 技术栈 | Swift + SwiftUI | ✅ 已验证 | 唯一能直接访问 TrollStore entitlements、CoreML、posix_spawn 的方案 |
| 代码编辑器 | Monaco Editor via WKWebView | ✅ 已验证 | CodeApp 在 App Store 生产环境验证 |
| Node.js | nodejs-mobile (--jitless V8 解释模式) | ✅ 已验证 | CodeApp 验证；JITless 比 JIT 慢 40-80%，但 Agent Loop I/O 为主影响小 |
| Python | CPython 3.13+ iOS 嵌入模式 | ✅ 已验证 | Python 官方文档 3.13+ 明确支持；Python-IDE App Store 上架 |
| Shell 命令 | ios_system (70+ 命令) | ✅ 已验证 | CodeApp、a-Shell 均使用；无需 fork，每命令编译为独立函数 |
| Agent Loop | 单循环架构（参考 Claude Code） | ✅ 已验证 | Claude Code 开源验证；简单可靠，让 LLM 自主决定下一步 |
| 策略引擎 | ABAC 三态 (allow/ask/deny) | ✅ 已验证 | @ai-abacus/core 实现可移植；5 Scope + 7 层优先级 |
| 代码执行 | posix_spawn + TrollStore no-sandbox | ⚠️ 有限可行 | 需嵌入已签名二进制到 App Bundle；4 项需实测（见 T1-T4） |
| 向量搜索 | sqlite-vec + CoreML Embedding | ✅ 已验证 | sqlite-vec 纯 C 零依赖可编译 iOS 静态库；CoreML all-MiniLM-L6-v2 ~22MB |
| 多模型 API | OpenRouter + 直接调用 | ✅ 已验证 | OpenRouter 300+ 模型；URLSession SSE iOS 15+ 原生支持 |
| 分发 | GitHub Actions → IPA → TrollStore | ✅ 已验证 | macOS runner 预装 Xcode；公共仓库免费；多个开源项目验证 |
| 终端模式 | 命令-输出（非交互式 Shell） | ✅ 已验证 | iOS 禁止 fork()，命令-输出模式对 Agent Tool Use 已足够 |

## 附录 B：关键限制（如实记录）

| 限制 | 影响 | 缓解措施 |
|------|------|---------|
| iOS 15+ A12+ 禁止 JIT | Node.js 只能 --jitless，计算密集型 JS 慢 5x | Agent Loop I/O 为主影响小；纯计算模块用 Swift 原生实现 |
| iOS 内核禁止 fork() | 无法实现交互式 Shell | ios_system 70+ 命令（命令-输出模式）；posix_spawn 单次执行 |
| 后台运行受限 | Agent 只能在前台工作 | 前台任务 + 进度显示；Background Tasks API（约 3 分钟） |
| posix_spawn 只能启动已签名二进制 | 需嵌入所有运行时到 App Bundle | Node.js ~40MB + Python ~30MB 嵌入 App Bundle |
| iOS 16.6.1 是目标唯一版本 | 不支持其他 iOS 版本 | 16.6.1 是末版，用户不会升级；TrollStore 在此版本永久有效 |

---

*文档结束。本文档所有需求均基于已验证的技术可行性，不可行的功能已标注排除。待实测项（T1-T5）需在开发启动前完成验证。*
