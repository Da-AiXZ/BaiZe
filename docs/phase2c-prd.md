# 白泽 Phase 2C 增量 PRD — 多模型支持

> **文档版本**：1.0 | **日期**：2026-06-17 | **作者**：许清楚（产品经理）
> **增量范围**：在 Phase 1 PRD 基础上，仅描述 Phase 2C 多模型支持相关需求
> **前置阶段**：Phase 2A（稳定性修复）✅ | Phase 2B（CI/CD + IPA 构建）✅

---

## 1. 项目信息

| 字段 | 值 |
|------|-----|
| Language | 中文 |
| Programming Language | Swift + SwiftUI (iOS 16.6.1) |
| Project Name | baize-phase2c |
| 原始需求 | 白泽从仅支持 OpenAI 扩展为支持 OpenAI + Anthropic + OpenRouter 三种 Provider，用户可自由切换模型 |

---

## 2. 产品目标

| # | 目标 | 度量标准 |
|---|------|---------|
| G1 | **Provider 可插拔**：LLMProvider 协议抽象，新增 Provider 零改动 AgentLoop | 新增 Provider 时 AgentLoop 代码变更行数 = 0 |
| G2 | **模型自由切换**：用户可在对话中实时切换 Provider 和模型，无需重启 | 切换后首 token 延迟 ≤ 正常请求延迟 + 200ms |
| G3 | **API 格式透明**：Anthropic/OpenRouter 的消息格式差异由 Provider 内部消化，上层代码无感知 | Message 模型不新增 case，AgentLoop 不感知 Provider 差异 |

---

## 3. 用户故事

| # | 用户故事 | 验收标准 |
|---|---------|---------|
| US-2C-1 | 作为一个 Developer，我想在设置中选择 Anthropic 作为 Provider 并输入 API Key，以便我使用 Claude 模型编写代码 | 选择 Anthropic → 输入 Key → 验证通过 → 可选 claude-sonnet-4-20250514 等模型并发起对话 |
| US-2C-2 | 作为一个 Developer，我想通过 OpenRouter 接入 DeepSeek/Gemini/Llama 等模型，以便我根据成本和质量灵活选择 | 输入 OpenRouter Key → 模型列表显示可用模型 → 选择任一模型可正常流式对话 |
| US-2C-3 | 作为一个 Developer，我想在对话进行中切换模型（如从 gpt-4o 切到 claude-sonnet-4-20250514），以便同一会话中按任务需要使用不同模型 | 点击模型选择器 → 切换模型 → 下一条消息使用新模型，对话历史不丢失 |
| US-2C-4 | 作为一个 Developer，我想看到当前使用的模型和 Provider 状态指示，以便我知道 Agent 正在用哪个模型 | 状态栏显示 Provider + 模型名，未配置 Key 时显示警告 |
| US-2C-5 | 作为一个 Developer，我想 Anthropic 的 tool_use 与 OpenAI 的 function calling 在 UI 上体验一致，以便我不需要关心底层 API 差异 | Anthropic tool_use 自动转换为 AgentLoop 的 ToolCall 格式，UI 展示与 OpenAI 一致 |

---

## 4. 需求池

### P0 — 必须有（Phase 2C 核心）

| # | 需求 | 说明 | 对应任务 |
|---|------|------|---------|
| 2C-P0-1 | **LLMProvider 协议** | 定义 `streamComplete` + `supportsFunctionCalling` + `availableModels`，作为所有 Provider 的统一抽象 | 2C-1 |
| 2C-P0-2 | **APIGateway 重构为 Provider 注册机制** | 移除硬编码 OpenAI 逻辑，改为 `providers: [String: LLMProvider]` 注册表，`streamComplete` 根据当前 activeProvider 委托 | 2C-2 |
| 2C-P0-3 | **OpenAIProvider** | 沿用现有 APIGateway 逻辑，包装为 LLMProvider 实现，消息格式和 SSE 解析不变 | 2C-3 |
| 2C-P0-4 | **AnthropicProvider** | 实现 Anthropic Messages API 适配：system 参数提取、Content Block 格式转换（tool_use/tool_result）、SSE event 类型解析（content_block_delta/message_delta） | 2C-4 |
| 2C-P0-5 | **OpenRouterProvider** | 复用 OpenAI 格式，添加 `HTTP-Referer` + `X-Title` header，model 参数映射（如 `deepseek/deepseek-chat`） | 2C-5 |
| 2C-P0-6 | **ModelSettingsView** | Provider 选择 Picker + 模型选择 Picker（根据 Provider 动态切换），替换现有 ModelSettingsPlaceholder | 2C-6 |

### P1 — 应该有（Phase 2C 增强）

| # | 需求 | 说明 | 对应任务 |
|---|------|------|---------|
| 2C-P1-1 | **APIKeySettingsView 增强** | 已支持三个 Key 输入（现有代码已实现），增加：连接验证真实 API 调用（非空即验证占位）、Key 输入错误提示 | 2C-7 |
| 2C-P1-2 | **Anthropic SSE 解析器扩展** | SSEStream 需支持 Anthropic 的 `event: content_block_delta` / `event: message_stop` 等事件类型，当前仅支持 OpenAI 的 `data: {...}` 格式 | 2C-4 |
| 2C-P1-3 | **模型列表动态获取** | OpenRouter 支持通过 `GET /api/v1/models` 获取可用模型列表，OpenAI/Anthropic 使用硬编码推荐列表 | 2C-6 |
| 2C-P1-4 | **AppState activeProvider 持久化** | 当前 activeProvider + activeModel 选择持久化到 UserDefaults，App 重启后恢复 | — |

### P2 — 可以有（Phase 3 预留）

| # | 需求 | 说明 |
|---|------|------|
| 2C-P2-1 | **自定义 Provider** | 用户可通过设置页添加任意 OpenAI 兼容端点（如本地 Ollama、vLLM） |
| 2C-P2-2 | **按任务类型自动路由** | 编程任务用 gpt-4o、规划任务用 claude-sonnet-4-20250514、快速任务用 deepseek-chat |
| 2C-P2-3 | **Token 用量按 Provider 统计** | Dashboard 显示各 Provider 的 Token 消耗和费用 |

---

## 5. 技术规范

### 5.1 LLMProvider 协议设计

```swift
/// LLM Provider 协议 — 所有模型提供商的统一抽象
protocol LLMProvider: Sendable {
    /// Provider 唯一标识
    var id: String { get }
    /// Provider 显示名称
    var displayName: String { get }

    /// 流式完成请求 — 返回统一的 LLMChunk 流
    func streamComplete(
        messages: [Message],
        tools: [ToolDefinition],
        model: String
    ) -> AsyncThrowingStream<APIGateway.LLMChunk, Error>

    /// 是否支持 Function Calling / Tool Use
    var supportsFunctionCalling: Bool { get }

    /// 可用模型列表
    var availableModels: [ModelInfo] { get }

    /// API Key 是否已配置
    var isConfigured: Bool { get }
}

/// 模型信息
struct ModelInfo: Identifiable, Hashable {
    let id: String          // 模型标识（如 "gpt-4o", "claude-sonnet-4-20250514"）
    let displayName: String // 显示名称
    let provider: String    // 所属 Provider ID
    let contextWindow: Int  // 上下文窗口大小
}
```

### 5.2 APIGateway 重构方向

**现有**：`APIGateway` 硬编码 OpenAI 请求构建 + SSE 解析

**目标**：
- `APIGateway` 变为 **Provider 注册表 + 委托层**
- `streamComplete` 根据 `activeProvider` 委托到对应 Provider
- 每个 Provider 内部封装自己的请求构建 + SSE 解析 + 格式转换
- `LLMChunk` 枚举不变（`textDelta` / `toolCallBegin` / `toolCallDelta` / `done`），AgentLoop 零改动

### 5.3 Anthropic API 适配要点

| 维度 | OpenAI | Anthropic | 适配策略 |
|------|--------|-----------|---------|
| 端点 | `POST /v1/chat/completions` | `POST /v1/messages` | Provider 各自构建 URLRequest |
| system 消息 | messages 数组中 `role: "system"` | 顶层 `system` 参数 | AnthropicProvider 从 messages 中提取 system，其余作为 messages |
| tool 定义 | `tools: [{type: "function", function: {...}}]` | `tools: [{name, description, input_schema}]` | AnthropicProvider 转换格式 |
| tool 调用 | `tool_calls: [{id, function: {name, arguments}}]` | `content: [{type: "tool_use", id, name, input}]` | AnthropicProvider 将 tool_use 转为 LLMChunk.toolCallBegin/Delta |
| tool 结果 | `role: "tool", tool_call_id, content` | `role: "user", content: [{type: "tool_result", tool_use_id, content}]` | AnthropicProvider 转换 toolResult 格式 |
| SSE 事件 | `data: {"choices":[{"delta":...}]}` | `event: content_block_delta`, `data: {"delta":...}` | SSEStream 需扩展 event 字段解析 |
| SSE 结束 | `data: [DONE]` | `event: message_stop` | AnthropicProvider 需处理不同结束标记 |
| Auth | `Authorization: Bearer $KEY` | `x-api-key: $KEY` + `anthropic-version: 2023-06-01` | Provider 各自构建 header |

### 5.4 OpenRouter 适配要点

| 维度 | 说明 |
|------|------|
| 兼容性 | 完全兼容 OpenAI `/v1/chat/completions` 格式 |
| 额外 Header | `HTTP-Referer: https://baize.app` + `X-Title: Baize` |
| model 参数 | 需使用全限定名（如 `deepseek/deepseek-chat`, `google/gemini-2.5-flash`） |
| API Key | `Authorization: Bearer $OPENROUTER_KEY` |
| 实现 | 继承 OpenAIProvider，仅覆盖端点 URL + header + model 映射 |

### 5.5 现有代码改动影响分析

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `APIGateway.swift` | **重构** | 拆分为 Provider 注册表 + 委托逻辑，原有 OpenAI 逻辑迁移到 OpenAIProvider |
| `SSEStream.swift` | **扩展** | 支持解析 `event:` 字段（当前仅处理 `data:` 字段），Anthropic 的 SSE 需要事件类型路由 |
| `KeychainService.swift` | **无改动** | 已支持三 Provider Key 存储 |
| `APIKeySettingsView.swift` | **小改** | 已支持三 Key 输入，需增加真实 API 验证 |
| `SettingsView.swift` | **小改** | 替换 ModelSettingsPlaceholder 为 ModelSettingsView |
| `AppState.swift` | **小改** | 已有 `activeProvider` + `activeModel`，需确保 Provider 切换联动 |
| `Message.swift` | **扩展** | 新增 `toAnthropicFormat()` 方法，现有 `toOpenAIFormat()` 不变 |
| `Constants.swift` | **扩展** | 新增 Anthropic/OpenRouter 端点常量 |
| `AgentLoop.swift` | **无改动** | LLMChunk 接口不变，AgentLoop 不感知 Provider 差异 |

---

## 6. UI 设计稿

### 6.1 ModelSettingsView（替换现有 ModelSettingsPlaceholder）

```
┌────────────────────────────────────────────┐
│  ← 默认模型                                │
├────────────────────────────────────────────┤
│                                            │
│  选择 Provider                             │
│  ┌──────────────────────────────────────┐  │
│  │ OpenAI                        ▼     │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  选择模型                                  │
│  ┌──────────────────────────────────────┐  │
│  │ gpt-4o                        ▼     │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  ───────────── Provider 详情 ──────────── │
│                                            │
│  🔗 OpenAI                                │
│  端点: api.openai.com                     │
│  Key:  sk-****                            │
│  状态: ✅ 已连接                           │
│  [验证连接]  [配置 Key]                    │
│                                            │
│  ───────────── 推荐模型 ───────────────── │
│                                            │
│  📋 编程（高质量）                          │
│    ○ gpt-4o           128K context        │
│    ○ claude-sonnet-4  200K context        │
│                                            │
│  📋 编程（高性价比）                        │
│    ○ deepseek-chat      64K context       │
│    ○ gpt-4o-mini       128K context       │
│                                            │
│  📋 快速任务                               │
│    ○ claude-haiku-4    200K context       │
│    ○ gpt-4o-mini       128K context       │
│                                            │
└────────────────────────────────────────────┘
```

### 6.2 APIKeySettingsView 增强（现有视图基础上微调）

```
┌────────────────────────────────────────────┐
│  ← API 配置                                │
├────────────────────────────────────────────┤
│                                            │
│  OpenAI ────────────────────────────────── │
│  [sk-***************] 👁                    │
│  ✅ 已验证  [保存] [验证连接] [删除]        │
│                                            │
│  Anthropic ─────────────────────────────── │
│  [sk-ant-**********] 👁                     │
│  ⚠️ 未验证  [保存] [验证连接] [删除]        │
│                                            │
│  OpenRouter ────────────────────────────── │
│  [sk-or-***********] 👁                     │
│  ❌ 未配置  [保存] [验证连接]               │
│                                            │
│  ─── 提示 ─────────────────────────────── │
│  至少配置一个 Provider 的 API Key 即可开始  │
│  使用。Anthropic 和 OpenRouter 为可选配置。  │
│                                            │
└────────────────────────────────────────────┘
```

### 6.3 设置主页更新

```
┌────────────────────────────────────────────┐
│  ← 设置                                    │
├────────────────────────────────────────────┤
│                                            │
│  🔑 API 配置                               │
│  已配置: OpenAI, Anthropic          ───▶  │
│                                            │
│  🤖 默认模型                               │
│  当前: OpenAI / gpt-4o              ───▶  │  ← subtitle 从 "当前: gpt-4o" 改为 "当前: Provider / model"
│                                            │
│  🛡️ 权限模式                               │
│  默认                               ───▶  │
│                                            │
│  💾 存储与运行时                     ───▶  │
│                                            │
│  ℹ️ 关于白泽                         ───▶  │
│                                            │
└────────────────────────────────────────────┘
```

### 6.4 对话界面模型指示器（状态栏区域）

```
┌────────────────────────────────────────────┐
│  白泽           OpenAI / gpt-4o  ▼    ⚙️   │  ← 新增 Provider/模型下拉
├────────────────────────────────────────────┤
│                                            │
│  对话内容...                               │
│                                            │
└────────────────────────────────────────────┘
```

---

## 7. 待确认问题

| # | 问题 | 影响 | 建议默认 |
|---|------|------|---------|
| Q-2C-1 | Anthropic 不支持在流式中同时返回文本和 tool_use（与 OpenAI 不同），AnthropicProvider 如何处理？ | AgentLoop 消费 LLMChunk 的逻辑可能需要微调 | AnthropicProvider 内部缓冲 content_block，按类型转换为 LLMChunk，对 AgentLoop 透明 |
| Q-2C-2 | OpenRouter 模型列表是否需要动态获取（`GET /api/v1/models`）？ | 影响模型列表的实现复杂度 | Phase 2C 先硬编码推荐模型列表（~20 个常用模型），动态获取作为 P1 |
| Q-2C-3 | Provider 切换时，对话历史的消息格式是否需要转换？ | 不同 Provider 的消息格式不同（如 Anthropic 的 tool_result 是 user role 下的 content block） | Provider 内部负责格式转换，对话存储统一使用 Message 模型，发送请求时由 Provider 转换 |
| Q-2C-4 | Anthropic 的 `anthropic-version` header 应使用哪个版本？ | 影响功能可用性 | 使用 `2023-06-01`（最新稳定版，支持 tool_use） |
| Q-2C-5 | Token 预算管理是否需要按 Provider 调整？不同模型 context window 差异很大（128K vs 200K vs 64K） | BaizeToken 常量当前硬编码 128K | 每个 ModelInfo 携带 contextWindow，Token 预算动态计算，不再硬编码 |

---

*文档结束。Phase 2C 核心目标：LLMProvider 协议抽象 + 三 Provider 实现 + 模型选择 UI，确保 AgentLoop 零改动。*
