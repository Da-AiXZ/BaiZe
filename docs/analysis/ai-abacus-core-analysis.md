# @ai-abacus/core 源码深度分析

> 版本：0.1.0 | 许可证：MIT | 发布时间：约 2026-05

---

## 1. 项目概述

### 1.1 定位与核心理念

**Abacus（算盘）是一个基于属性的访问控制（ABAC）运行时，专为 AI Agent 的行为护栏（guardrails）而设计。**

核心问题：Agent 具有类似用户的权限控制需求，但还需要额外的护栏来防止被胁迫（coerced）的行为。在沙盒环境中，Agent 访问敏感资源（密钥、文件系统、网络）时，需要安全、透明、可审计的决策机制。

Abacus 的三大目标：
1. **可配置的规则引擎** — 为 Agent 提供灵活的行为护栏
2. **可审计的决策** — 对评估的动作产生 allow/ask/deny 三态决策
3. **快速且可移植的运行时** — 基于 OPA Wasm 实现跨平台高性能

### 1.2 设计哲学

- **声明式策略**：通过 TOML 配置文件声明策略，而非硬编码
- **三层决策模型**：`deny`（拒绝） > `ask`（需人工确认） > `allow`（允许）
- **确定性优先级**：规则匹配结果完全确定，无歧义
- **Wasm 沙盒执行**：策略评估在 OPA Wasm 沙盒中运行，与宿主隔离

### 1.3 资源域（Scope）

Abacus 管控 Agent 访问的五类关键资源：

| Scope | 说明 | 可用动词 |
|-------|------|----------|
| `tool` | 可复用的预编码工作流/工具 | use, read, edit, create, delete, * |
| `skill` | 可复用的提示词模板 | use, read, edit, create, delete, * |
| `fs` | 文件系统 | use, read, edit, create, delete, * |
| `net` | 网络访问 | get, post, put, patch, delete, options, head, * |
| `secret` | 密钥/凭证 | use, read, edit, create, delete, * |

---

## 2. 架构概览

### 2.1 模块结构

```
@ai-abacus/core/
├── dist/
│   ├── index.js / index.d.ts      # 公共 API 入口
│   ├── engine.js / engine.d.ts    # 核心类型定义（Scope, Action, Decision, Input）
│   ├── config/
│   │   ├── schema.js / schema.d.ts      # 类型常量 + SOURCE_PRIORITY 优先级映射
│   │   ├── validate.js / validate.d.ts  # Zod schema 验证
│   │   ├── normalize.js / normalize.d.ts # TOML → NormalizedPolicy 转换
│   │   └── resolve.js / resolve.d.ts    # 纯 TS 规则匹配（备选路径）
│   └── policy/
│       ├── runtime.js / runtime.d.ts    # OPA Wasm 运行时封装
│       └── bundle/
│           └── policy.wasm              # 预编译的 Rego 策略 Wasm 二进制
├── package.json
└── README.md
```

### 2.2 核心类/接口

#### Input（评估请求）

```typescript
type Input = {
  requestId: string;       // 请求唯一标识
  timestamp: string;       // ISO 时间戳
  agent?: string;          // Agent 名称（可选，用于规则匹配）
  actor: Actor;            // 执行者信息
  action: Action;          // 动作标识，如 "tool::use"
  context: ContextByScope; // 上下文信息，按 scope 类型分化
}
```

#### Action（动作类型）

采用 `scope::verb` 格式的字符串字面量联合类型：
- `tool::use`, `fs::read`, `net::get`, `secret::read`, `skill::use` 等
- TypeScript 模板字面量类型确保编译时校验

#### Decision（决策结果）

```typescript
type Decision = {
  policyVersion: string;
  effect: 'deny' | 'ask' | 'allow';
  reasons: string[];
  source: string;       // 匹配规则来源层
  ruleId?: string;      // 匹配规则 ID
}
```

#### NormalizedPolicy（标准化策略）

```typescript
type NormalizedPolicy = {
  meta: NormalizedPolicyMeta;  // 策略元信息
  rules: NormalizedRule[];     // 排序后的规则列表
}
```

### 2.3 数据流

```
TOML 配置文件
    │
    ▼ parsePolicyToml() / loadPolicy()
RawPolicyConfig (Zod 验证)
    │
    ▼ normalizePolicy()
NormalizedPolicy (规则排序、优先级计算)
    │
    ▼ buildRegoInput()
RegoEvalInput { config, request }
    │
    ▼ evaluateWithOpaWasm()
OPA Wasm 执行 Rego 策略
    │
    ▼ readRegoDecisionFromWasmResult() + toEngineDecision()
Decision { effect, reasons, source, ruleId }
```

---

## 3. 核心算法

### 3.1 规则优先级体系

Abacus 使用 7 层确定性优先级体系，从高到低：

| Source Layer | 优先级 | 说明 |
|-------------|--------|------|
| `override_exact` | 700 | 覆盖规则（精确匹配） |
| `override_wildcard` | 650 | 覆盖规则（通配符匹配） |
| `agent_rule_exact` | 600 | Agent 特定规则（精确匹配） |
| `agent_rule_wildcard` | 550 | Agent 特定规则（通配符匹配） |
| `agent_default` | 500 | Agent 默认策略 |
| `global_default` | 400 | 全局默认策略 |
| `permission_mode` | 100 | 权限模式回退 |

**决定规则层级的启发式算法**：
- `override` 前缀：来自 `[overrides]` 数组的显式覆盖
- `agent_rule` 前缀：来自 `[agents.<name>]` 的规则
- `_exact` 后缀：verb 非 `*` 或 match 字段中有具体值
- `_wildcard` 后缀：verb 为 `*` 且 match 全为通配符

### 3.2 规则排序（5 级排序键）

```javascript
rules.sort((a, b) => {
  // 1. priority (higher wins)
  // 2. specificity (higher wins) — 具体匹配字段数量 + 精确 verb
  // 3. agent rank (具体 agent > "*")
  // 4. effect restrictiveness (deny > ask > allow)
  // 5. id lexical tie-break
})
```

### 3.3 匹配算法

#### Glob 匹配
- `*` → `.*`，`?` → `.`
- 支持 case-insensitive / case-sensitive 模式

#### Tokenized Argv 匹配（核心创新点）
Tool scope 的 `argv` 采用**子序列匹配**而非完全匹配：

```javascript
function matchArgvSubsequence(ruleArgv, inputArgv, caseSensitive) {
  let seekIndex = 0;
  for (const token of inputArgv) {
    if (matchGlob(ruleArgv[seekIndex], token, caseSensitive)) {
      seekIndex += 1;
      if (seekIndex >= ruleArgv.length) return true;
    }
  }
  return false;
}
```

例如，规则 `argv: ["git", "push"]` 可匹配 `["git", "push", "--force"]`，但不匹配 `["git", "pull"]`。这使得规则只需指定关键命令片段，而不必穷举所有参数组合。

### 3.4 双引擎架构

Abacus 同时实现了两套评估引擎：

1. **OPA Wasm 引擎**（主路径）— `evaluateWithOpaWasm()`
   - 策略逻辑在 Rego 中实现，编译为 Wasm
   - 好处：策略执行与宿主完全隔离，策略不可篡改
   - Wasm 二进制（365KB）随包发布

2. **纯 TypeScript 解析引擎**（备选路径）— `resolveDecision()`
   - 在 `config/resolve.js` 中实现
   - 不依赖 OPA Wasm
   - 可用于测试或轻量场景

3. **OPA CLI 引擎**（开发路径）— `evaluateWithOpaCli()`
   - 直接调用 `opa eval` 命令行
   - 仅用于开发/调试

### 3.5 Wasm 加载与缓存

```javascript
let cachedPolicyPath;
let cachedPolicyPromise;

async function getLoadedPolicy(options) {
  const wasmPath = ensurePolicyWasm(options);
  if (!cachedPolicyPromise || cachedPolicyPath !== wasmPath) {
    cachedPolicyPath = wasmPath;
    cachedPolicyPromise = readFile(wasmPath).then(bytes => loadPolicy(bytes));
  }
  return cachedPolicyPromise;
}
```

- 单例缓存，避免重复加载 Wasm
- 自动构建回退：若 `policy.wasm` 不存在，且检测到本地 Rego 源码，自动调用 `opa build`

---

## 4. Agent Integration

### 4.1 Agent 粒度的策略控制

Abacus 原生支持多 Agent 差异化权限：

```toml
[agents.build.tool]
use = { "*" = "allow" }     # build agent 可用所有工具

[agents.review.fs]
read = { "*" = "allow" }    # review agent 只读文件
edit = { "*" = "deny" }
```

Input 中的 `agent` 字段用于匹配 `[agents.<name>]` 下的规则。

### 4.2 Actor 与 Permission 机制

```typescript
type Actor = {
  id: string;
  permissions: Record<string, Decision['effect']>;
}
```

Actor 携带预授的权限映射，但当前版本中 permissions 字段在规则评估中未直接使用——权限决策完全由策略规则驱动。

### 4.3 ask 决策与人工确认

三态决策中的 `ask` 是 Abacus 的关键创新：
- `allow`：自动放行
- `ask`：需要人工确认后才能执行
- `deny`：直接拒绝

这为 Agent 系统提供了"半自动"模式——低风险操作自动放行，高风险操作需人工介入。

### 4.4 集成方式

```typescript
// 方式1：一次性评估
const decision = await evaluate(input, { configToml });

// 方式2：创建可复用引擎
const engine = await createEngine({ configToml });
const decision = await engine.evaluate(input);

// 方式3：预编译策略
const policy = parsePolicyToml(configToml);
const engine = await createEngine({ policy });
```

---

## 5. API 设计

### 5.1 公共 API 清单

| API | 类型 | 说明 |
|-----|------|------|
| `evaluate(input, options?)` | 异步函数 | 一次性评估，最简单的使用方式 |
| `createEngine(options?)` | 异步工厂 | 创建可复用引擎，避免重复加载 Wasm |
| `loadPolicy(options?)` | 异步函数 | 加载并解析策略（支持文件系统发现） |
| `parsePolicyToml(configToml)` | 同步函数 | 从 TOML 字符串解析策略 |
| `parseRawPolicyConfig(raw)` | 同步函数 | Zod 验证原始配置 |
| `normalizePolicy(raw)` | 同步函数 | 标准化策略（计算优先级、排序规则） |

### 5.2 配置发现机制

`loadPolicy()` 按以下顺序查找配置文件：
1. 显式 `configPath` 参数
2. `ABACUS_CONFIG_PATH` 环境变量
3. `./abacus.toml`（当前工作目录）
4. `~/.config/abacus/abacus.toml`（用户配置目录）

### 5.3 TOML 配置结构

```toml
[policy]
version = "2026-05"             # 审计版本号
permission_mode = "strict"      # strict | relax | dangerous
pattern_dialect = "glob"        # 仅支持 glob
pattern_case = "insensitive"    # insensitive | sensitive
tool_match_mode = "tokenized_argv"

[default.tool.use]
"*" = "allow"

[default.net.get]
"*.example.com" = "allow"

[agents.build.tool]
use = { "*" = "allow" }

[agents.build.fs]
read = { "*" = "allow" }
edit = { "/tmp/*" = "allow" }

[[overrides]]
scope = "tool"
verb = "use"
tool = "webfetch"
effect = "deny"
reason = "block_webfetch"
```

### 5.4 设计模式总结

1. **分层抽象**：验证（Zod）→ 标准化 → 评估（Wasm/TS 双引擎）
2. **策略模式**：策略与引擎解耦，策略可预编译复用
3. **约定优于配置**：默认查找路径、默认 permission_mode=strict
4. **不可变决策**：Decision 为纯数据对象，无副作用
5. **sideEffects: false**：包标记为无副作用，支持 tree-shaking

---

## 6. 依赖分析

| 依赖 | 用途 |
|------|------|
| `@open-policy-agent/opa-wasm` ^1.10.0 | OPA Wasm 运行时，加载和执行编译后的 Rego 策略 |
| `smol-toml` ^1.6.1 | 轻量 TOML 解析器 |
| `zod` ^4.4.3 | 运行时类型验证和 schema 定义 |

---

## 7. 对 iOS 本地 Agent 的启示

### 7.1 Wasm 策略引擎 → iOS 原生策略引擎

Abacus 使用 OPA Wasm 执行策略评估，这对 iOS 有重要启示：

- **Wasm on iOS**：SwiftWasm 或 wasmtime 可在 iOS 上运行 Wasm，但性能和包体积需要权衡。Abacus 的 policy.wasm 为 365KB，在移动端可接受。
- **替代方案**：Abacus 自带的纯 TS `resolveDecision()` 证明了纯逻辑引擎的可行性。iOS 可用 Swift 实现等效的规则匹配引擎，无需 Wasm 依赖。
- **推荐路径**：iOS 本地 Agent 优先采用**纯 Swift 规则引擎**，参考 Abacus 的 `normalize.js` + `resolve.js` 的逻辑实现。

### 7.2 ABAC 权限模型 → iOS Agent 沙盒

Abacus 的 ABAC 模型直接映射到 iOS Agent 场景：

| Abacus Scope | iOS Agent 场景 |
|-------------|---------------|
| `tool` | Agent 可调用的工具（文件操作、代码执行、终端命令） |
| `fs` | 文件系统访问（项目文件、配置、缓存） |
| `net` | 网络请求（API 调用、包下载、LLM 推理） |
| `secret` | Keychain 访问、API Key、Token |
| `skill` | Prompt 模板、指令集 |

### 7.3 三态决策模型 → iOS 人工确认流程

`allow/ask/deny` 三态模型完美适配 iOS 交互模式：

- **allow** → 静默执行
- **ask** → 弹出系统级确认对话框（类似 iOS 权限请求）
- **deny** → 拒绝执行，返回错误

这比简单的二态（allow/deny）更适合 AI Agent 场景，因为某些操作（如删除文件、发送网络请求）在上下文明确时可以自动允许，但在模糊场景下应征求用户确认。

### 7.4 Tokenized Argv 匹配 → iOS 命令行工具控制

Abacus 的 `tokenized_argv` 匹配模式可用于控制 iOS Agent 的工具调用：
- 规则 `tool: "bash", argv: ["git", "push"]` 可匹配 `git push --force`
- iOS Agent 可用类似机制控制 Shell 命令执行

### 7.5 配置即策略 → iOS 策略热更新

- Abacus 使用 TOML 声明策略，策略与代码分离
- iOS Agent 可将策略文件放在 App Bundle 或 iCloud 中，支持不更新 App 即可调整权限
- 建议格式：JSON 或 Plist（iOS 原生友好），而非 TOML

### 7.6 确定性优先级 → iOS 安全保证

Abacus 的 5 级确定性排序确保了：
- 永远不会出现"两条规则冲突且无法决定"的情况
- override 规则优先级最高，确保管理员可以强制覆盖
- iOS Agent 需要类似保证：系统级限制（如不允许 Agent 访问其他 App 数据）必须不可被 Agent 规则覆盖

### 7.7 关键架构建议

1. **双层策略架构**：
   - 系统策略（不可覆盖）：iOS 系统级限制，硬编码在 App 中
   - 用户策略（可覆盖）：用户自定义的 Agent 行为护栏，通过配置文件声明

2. **策略评估前置于工具调用**：
   - Agent 每次调用工具前，先通过策略引擎评估
   - 评估结果决定是否执行、是否弹窗确认、或直接拒绝

3. **审计日志**：
   - 每个决策（包括 requestId、action、effect、reason）应持久化
   - 用于事后审计和调试

4. **性能优化**：
   - 策略引擎应在 App 启动时初始化，避免每次评估时重新加载
   - 规则匹配是 O(n) 线性扫描（n = 规则数），对于合理的规则数量（<1000）足够快

5. **Swift 实现参考**：
   - `NormalizedPolicy` → Swift struct，符合 Codable
   - `resolveDecision()` → Swift 函数，使用 for-loop + glob 匹配
   - `matchArgvSubsequence()` → 直接移植为 Swift 函数
   - 决策结果用 async/await + continuation 桥接 UI 确认流程

---

## 8. 总结

@ai-abacus/core 是一个设计精良的 Agent 访问控制运行时，其核心贡献在于：

1. **将 ABAC 模型引入 Agent 领域**，定义了 5 个关键资源域和统一的 action 命名空间
2. **三态决策模型**（allow/ask/deny）比传统二态更适合 Agent 场景
3. **确定性优先级体系**消除了策略冲突歧义
4. **OPA Wasm + 纯 TS 双引擎**兼顾了安全隔离和轻量部署
5. **Tokenized Argv 匹配**为工具调用控制提供了优雅的解决方案

对于 iOS 本地 Agent 开发，Abacus 的权限模型和决策机制可以直接移植为 Swift 原生实现，核心算法（规则标准化、优先级排序、glob 匹配、argv 子序列匹配）都不依赖 Wasm，适合在移动端高效运行。
