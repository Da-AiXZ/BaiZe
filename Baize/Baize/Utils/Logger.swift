import os

/// 白泽统一日志器 — 基于 os.Logger
/// 按模块分类，支持 debug/info/error/fault 四级日志
/// 日志规范：
///   debug: SSE chunk 详情、posix_spawn 参数、Monaco JS 调用
///   info: Agent Loop 迭代开始/结束、工具调用/结果、文件操作
///   error: API 调用失败、posix_spawn 失败、文件操作失败
///   fault: 数据损坏、不可恢复错误

/// General — 通用日志
let baizeLogger = Logger(subsystem: "com.baize.app", category: "General")

/// Agent — Agent Loop、ContextManager 相关日志
let agentLogger = Logger(subsystem: "com.baize.app", category: "Agent")

/// API — APIGateway、SSEStream 相关日志
let apiLogger = Logger(subsystem: "com.baize.app", category: "API")

/// Tool — 工具执行相关日志
let toolLogger = Logger(subsystem: "com.baize.app", category: "Tool")

/// Runtime — RuntimeExecutor、posix_spawn 相关日志
let runtimeLogger = Logger(subsystem: "com.baize.app", category: "Runtime")

/// UI — 视图层相关日志
let uiLogger = Logger(subsystem: "com.baize.app", category: "UI")