# 白泽 iOS 编程智能体 — 项目概览

## TL;DR
设计并实现了白泽 Phase 1 的完整代码 — 一个运行在 iPad Pro M1 上的本地编程智能体，像 Claude Code 一样强大，但所有工具执行在本地完成。

## 标准 SOP 流程

| 阶段 | 成员 | 产出 | 状态 |
|------|------|------|------|
| 需求分析 | 许清楚（PM） | baize-prd.md | ✅ 完成 |
| 架构设计 | 高见远（架构师） | baize-architecture.md | ✅ 完成 |
| 代码实现 | 寇豆码（工程师） | 46 个 Swift 文件 + 配置 | ✅ 完成 |
| QA 审查 | 严过关（QA） | baize-qa-report.md | ✅ 完成（8 Critical 已修复） |

## 交付文件

### 核心文档
- `baize-prd.md` — 产品需求文档（P0/P1/P2 分级，13 项 Phase 1 功能）
- `baize-architecture.md` — 系统架构设计（三层架构 + 5 任务 + 类图 + 时序图）
- `baize-qa-report.md` — QA 审查报告（8 Critical + 23 Warning，Critical 全部修复）
- `白泽-技术可行性逐项验证报告.md` — 技术可行性逐项验证
- `白泽-iOS本地编程智能体-完整架构方案.md` — 完整架构方案（研究阶段产出）

### 源码（46 个 Swift 文件）
- `Baize/Baize/Agent/` — AgentLoop, AgentEvent, Message, Tool, ToolCall, ToolResult, ToolRegistry, PermissionEngine, ProjectContext, ContextManager, ConversationStore
- `Baize/Baize/Infrastructure/` — APIGateway, SSEStream, FileSystemService, KeychainService, RuntimeExecutor, MonacoBridge
- `Baize/Baize/Tools/` — 9 个工具实现（ReadFile, WriteFile, EditFile, ListDirectory, SearchFiles, SearchContent, ExecuteCommand, RunNode, RunPython）
- `Baize/Baize/Views/` — 15 个 SwiftUI 视图
- `Baize/Baize/App/BaizeApp.swift` — 应用入口
- `Baize/Baize/Utils/` — Constants, Logger, Extensions
- `Baize/Baize/Models/` — AppState, EditorState

### 配置
- `Package.swift` — SPM 依赖
- `Baize/Baize/Baize.entitlements` — TrollStore entitlements
- `Baize/Baize/Info.plist` — App 元数据
- `.github/workflows/build.yml` — GitHub Actions CI/CD
- `Baize/Baize/Resources/monaco-editor/index.html` — Monaco Editor 资源

### 研究报告（8 份，位于 analysis/）
- core-source-analysis.md, agent-frameworks-analysis.md, harness-governance-analysis.md
- memory-skill-planning-analysis.md, context-engineering-analysis.md
- ai-abacus-core-analysis.md, ios-feasibility-research.md, papers-and-links-analysis.md

## 关键技术选型
- Swift + SwiftUI 原生开发
- Monaco Editor (WKWebView) 代码编辑
- nodejs-mobile (--jitless) + CPython 3.13+ 代码执行
- ios_system Shell 命令（命令-输出模式）
- ABAC 三态策略引擎（allow/ask/deny）
- OpenAI API SSE 流式（AsyncThrowingStream）
- GitHub Actions → TrollStore 免签分发

## 下一步
1. 创建 GitHub 仓库并推送代码
2. 在 macOS runner 上验证编译
3. 在 iPad Pro M1 上通过 TrollStore 安装测试
4. 配置 OpenAI API Key 进行端到端测试
5. 嵌入 nodejs-mobile 和 CPython 运行时二进制
