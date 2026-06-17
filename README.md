# 白泽 (BaiZe) 🐉

> iOS 本地编程智能体 — Local Coding Agent on iPad

<p align="center">
  <strong>像 Claude Code 一样强大，本地运行在你的 iPad 上</strong>
</p>

---

## 🎯 项目愿景

白泽是一个运行在 iPad Pro 2021 M1 (iOS 16.6.1) 上的本地编程智能体，通过 TrollStore 免签安装，提供类似 Claude Code / Codex 的 AI 编程体验。

**核心能力**：
- 🤖 AI Agent Loop：用户输入 → LLM 推理 → 工具调用 → 执行 → 结果注入 → 循环
- 📝 Monaco Editor：内嵌代码编辑器（WKWebView）
- ⚡ 代码执行：Node.js (--jitless) / Python 3 / Shell 命令
- 🔒 权限引擎：allow/ask/deny 三态，4 种安全模式
- 📂 项目上下文：BAIZE.md 配置文件（类 CLAUDE.md）

## 🏗️ 架构

```
┌─────────────────────────────────────────┐
│              UI Layer (SwiftUI)          │
│  ContentView ─ Chat ─ Editor ─ Settings │
├─────────────────────────────────────────┤
│          Business Layer (Agent)          │
│  AgentLoop ─ ToolRegistry ─ Permission │
│  ContextManager ─ ProjectContext        │
├─────────────────────────────────────────┤
│        Infrastructure Layer              │
│  APIGateway ─ SSE ─ FileSystem ─ Runtime│
│  Keychain ─ MonacoBridge                │
└─────────────────────────────────────────┘
```

**技术栈**：Swift + SwiftUI | SPM | Actor 并发 | OpenAI API SSE | posix_spawn

## 🛠️ 9 个内置工具

| 工具 | 类型 | 说明 |
|------|------|------|
| ReadFile | 只读 | 读取文件内容 |
| WriteFile | 破坏性 | 写入/创建文件 |
| EditFile | 破坏性 | 精确字符串替换 |
| ListDirectory | 只读 | 列出目录内容 |
| SearchFiles | 只读 | Glob 模式搜索文件 |
| SearchContent | 只读 | Grep 搜索内容 |
| ExecuteCommand | 破坏性 | 执行 Shell 命令 (ios_system) |
| RunNode | 破坏性 | 执行 Node.js 脚本 (--jitless) |
| RunPython | 破坏性 | 执行 Python 脚本 |

## 📦 项目结构

```
BaiZe/
├── Baize/
│   ├── App/           # @main 入口
│   ├── Agent/         # Agent 循环 + 工具 + 权限
│   ├── Infrastructure/# API + SSE + 文件系统 + 运行时
│   ├── Tools/         # 9 个内置工具实现
│   ├── Views/         # SwiftUI 视图层
│   ├── Models/        # 数据模型
│   └── Utils/         # 常量 + 扩展 + 日志
├── Package.swift       # SPM 配置
├── .github/workflows/  # CI/CD → IPA
└── docs/              # PRD + 架构 + 分析报告
```

## 🚀 构建 & 安装

### 前置条件
- macOS 14+ with Xcode 15.4+
- iPad Pro 2021 M1, iOS 16.6.1
- TrollStore 已安装

### 通过 GitHub Actions（推荐）
1. Push 到 `main` 分支
2. GitHub Actions 自动构建 IPA
3. 下载 Artifact → TrollStore 安装

### 本地构建
```bash
xcodebuild -scheme BaizeKit \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  build
```

## 📊 开发进度

| 阶段 | 状态 | 内容 |
|------|------|------|
| Phase 1 | ✅ 完成 | PRD + 架构 + 代码 + QA 静态审查 |
| Phase 2A | ✅ 完成 | P0 Warning 修复（DI 重构/超时/SSE/continuation） |
| Phase 2B | 🔜 进行中 | 真机构建验证 + P1 Warning 修复 |
| Phase 2C | 📋 计划中 | 多模型支持（Anthropic + OpenRouter） |
| Phase 2D | 📋 计划中 | Monaco Editor 真实集成 |

## 🔐 安全

- TrollStore 提供的 `no-sandbox` + `platform-application` entitlements
- iOS 禁止 `fork()` 和 JIT 编译
- 所有 spawned binary 必须 signed 且在 App Bundle 内
- Permission Engine 三态策略 + 4 种模式
- 危险命令黑名单（`rm -rf /`, `fork()`, `reboot` 等）

## 📄 许可证

私有项目，未授权禁止使用。

---

<p align="center">
  <i>白泽 — 上古知万物之神兽，今为你的编程伙伴</i> 🐉
</p>
