# iPad Pro M1 (iOS 16.6.1) 本地编程智能体技术可行性研究报告

> 研究日期: 2026-06-17
> 目标设备: iPad Pro M1 (arm64e), iOS 16.6.1
> 研究目标: 评估在 iPad Pro M1 上构建"白泽"本地编程智能体的技术可行性

---

## 目录

1. [iOS 应用技术栈选择](#1-ios-应用技术栈选择)
2. [TrollStore 免签安装](#2-trollstore-免签安装)
3. [GitHub Actions 交叉编译 iOS IPA](#3-github-actions-交叉编译-ios-ipa)
4. [本地代码执行沙箱](#4-本地代码执行沙箱)
5. [多模型 API 集成](#5-多模型-api-集成)
6. [本地向量数据库/Embedding](#6-本地向量数据库embedding)
7. [竞品分析](#7-竞品分析)
8. [综合评估与建议](#8-综合评估与建议)

---

## 1. iOS 应用技术栈选择

### 结论: **Swift + SwiftUI（推荐）**

### 详细对比

| 维度 | Swift + SwiftUI | Flutter | React Native |
|------|----------------|---------|--------------|
| **性能** | 原生性能，直接调用 iOS API | Skia 渲染，接近原生但有权重开销 | JS Bridge 桥接，性能最低 |
| **iOS 系统级 API 访问** | 完全访问（CoreML, Metal, Network 等） | 通过 Platform Channel 调用，需写原生桥接 | 通过 Native Module 桥接，复杂度更高 |
| **TrollStore 特权 API** | 直接使用 entitlements，无障碍 | 需要通过 MethodChannel 桥接 | 需要通过 Native Module 桥接 |
| **CoreML 集成** | 原生支持 | 需要插件 | 需要原生模块 |
| **文件系统访问** | 原生 FileManager | 通过插件访问 | 通过插件访问 |
| **SSE/网络流** | URLSession + AsyncStream 原生支持 | dart:http 支持 | 需要 polyfill |
| **代码编辑器 UI** | 需自建（但可参考 SwiftStitch 等） | 丰富文本编辑器生态 | 丰富文本编辑器生态 |
| **开发效率** | 需 Mac + Xcode | 任意平台 | 任意平台 |
| **App 体积** | 最小（~5-10MB） | 中等（~20-40MB，含 Flutter Engine） | 较大（~30-50MB，含 JSC/Hermes） |

### 推荐理由

**Swift + SwiftUI 是唯一选择**，原因如下：

1. **系统级 API 需求**: 编程智能体需要访问文件系统、进程管理（TrollStore 环境下）、CoreML 等，这些只有 Swift 能直接、无缝访问
2. **TrollStore 集成**: TrollStore 的 entitlements、unsandboxing、root helper 等能力全部是 ObjC/Swift 层面的，跨平台框架需要大量原生桥接代码，得不偿失
3. **CoreML 本地推理**: 本地 embedding 模型运行依赖 CoreML，Swift 是最自然的集成方式
4. **性能敏感操作**: 代码编辑、语法高亮、向量搜索等需要原生性能
5. **SwiftUI 成熟度**: iOS 16 时 SwiftUI 已足够成熟，支持复杂 UI 构建

### 注意事项

- 必须使用 Xcode 开发，需要 Mac 或 GitHub Actions macOS runner
- SwiftUI 在 iOS 16 上有一些已知 bug（如 NavigationStack 的部分问题），但可规避
- 代码编辑器组件需要自建，iOS 上没有像 Monaco Editor 那样成熟的方案

### 替代方案

如果团队只有 Web/Flutter 经验，可考虑 **Swift UI 壳 + WKWebView 混合方案**：核心 UI 用 SwiftUI，代码编辑器部分嵌入 WebView 运行 Monaco Editor（VS Code 同款编辑器）。CodeApp for iPad 正是采用此方案。

---

## 2. TrollStore 免签安装

### 结论: **完全可行，iOS 16.6.1 在支持范围内**

### 2.1 iOS 16.6.1 + iPad Pro M1 支持情况

**TrollStore 官方支持版本**: iOS 14.0 beta 2 - 16.6.1, 16.7 RC, 17.0

iPad Pro M1 (arm64e) + iOS 16.6.1 **完全在支持范围内**。

安装工具推荐: **TrollInstallerX**（支持 iOS 14.0 - 16.6.1 全设备）

**关键细节**: iPad Pro M1 (arm64e) 在 iOS 16.6.1 上需要使用 **间接安装法 (Indirect Installation)**，因为:
- iOS 16.6+ arm64e 缺少 PPL bypass (dmaFail)
- 间接法会替换一个系统应用为 TrollStore persistence helper
- 安装后 TrollStore 可正常工作

### 2.2 TrollStore 安装 IPA 的特权

| 能力 | 正常 App Store 应用 | TrollStore 安装应用 |
|------|---------------------|---------------------|
| **沙箱** | 严格沙箱限制 | 可完全去除沙箱 |
| **文件系统访问** | 仅 App Container | 可访问整个文件系统 |
| **进程创建 (posix_spawn)** | 仅沙箱内限制 | 可 spawn 任意二进制 |
| **Root 权限执行** | 不可能 | 通过 Root Helper 可实现 |
| **自定义 Entitlements** | 仅 Apple 允许的 | 任意 entitlements |
| **持久性** | 永久 | 需要 Persistence Helper 维护 |
| **后台运行** | 严格限制 | 同系统限制（TrollStore 不解决此问题） |

### 2.3 关键 Entitlements

**去除沙箱** (推荐 `no-sandbox`，保留数据容器):
```xml
<key>com.apple.private.security.no-sandbox</key>
<true/>
<key>platform-application</key>
<true/>
<key>com.apple.private.security.storage.AppDataContainers</key>
<true/>
```

**Root 进程执行**:
```xml
<key>com.apple.private.persona-mgmt</key>
<true/>
```
使用 `posix_spawn` + `spawnRoot` 函数可启动 Root Helper 二进制。

### 2.4 iOS 15+ A12+ (含 M1) 被禁止的 Entitlements

以下三个 entitlements **在 TrollStore 中也不可用**（需要 PPL bypass，TrollStore 不提供）：

- `com.apple.private.cs.debugger` — 调试器
- `dynamic-codesigning` — 动态代码签名（JIT 编译所需）
- `com.apple.private.skip-library-validation` — 跳过库验证

**影响**: 无法使用 JIT 编译，无法动态加载未签名代码。这意味着:
- 不能运行解释型语言的 JIT 模式（如 Python 的 JIT、V8 的 TurboFan）
- 但可以使用 AOT 编译或解释模式
- WebAssembly 可以运行（WASM 不需要 JIT）

### 2.5 TrollStore 限制

- **无法获得 Platformization** (`TF_PLATFORM` / `CS_PLATFORMIZED`)
- **无法启动 Launch Daemon**（后台常驻进程）
- **无法注入 Tweak 到系统进程**
- **图标缓存刷新后**需手动用 Persistence Helper 重新注册
- **iOS 系统更新会破坏 TrollStore**（16.6.1 已是末版，一般不会更新）

### 2.6 TrollStore 安装应用能否访问 Shell/Terminal?

**可以，但有条件**:

1. 使用 `posix_spawn` 可以启动系统自带或自带的二进制文件
2. 需要去除沙箱 (`no-sandbox`) + `platform-application` entitlements
3. 可以将自定义二进制打包进 App Bundle，然后 spawn 执行
4. 可以以 Root 权限执行（需要 `persona-mgmt` entitlement）
5. **不能** fork + exec（iOS 不允许 fork），只能 posix_spawn
6. **不能** 使用 JIT（禁止 `dynamic-codesigning`），限制了某些运行时

### 权威来源

- TrollStore 官方仓库: https://github.com/opa334/TrollStore
- TrollInstallerX: https://github.com/alfiecg24/TrollInstallerX
- iOS CFW Guide: https://ios.cfw.guide/installing-trollstore

---

## 3. GitHub Actions 交叉编译 iOS IPA

### 结论: **完全可行，macOS runner 提供完整 Xcode 环境**

### 3.1 不需要自有 Mac？

**不完全正确**。你不需要一台始终在线的 Mac，但 GitHub Actions 的 macOS runner **本身就是运行 macOS 的云服务器**，上面预装了完整的 Xcode。

也就是说：**代码开发可以在任意平台完成，编译通过 GitHub Actions 在云端 macOS 上完成，IPA 产物下载后通过 TrollStore 安装到 iPad**。

### 3.2 GitHub Actions macOS Runner 能力

| 能力 | 支持情况 |
|------|----------|
| **Xcode** | 预装最新版 Xcode（通常包含多个版本） |
| **xcodebuild** | 完整支持，可 archive + export IPA |
| **Swift 编译** | 完整支持 |
| **CocoaPods / SPM** | 完整支持 |
| **代码签名** | 支持（需配置证书和 Profile） |
| **App Store 上传** | 支持（需 Apple Developer 账号） |
| **TrollStore IPA 导出** | 支持（CODE_SIGNING_ALLOWED=NO + 手动打包） |

### 3.3 TrollStore IPA 的 CI/CD 流程

对于 TrollStore 安装场景，**不需要 Apple Developer 证书**（免签），流程更简单：

```yaml
name: Build TrollStore IPA

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Archive (No Signing)
        run: |
          xcodebuild archive \
            -project Baize/Baize.xcodeproj \
            -scheme Baize \
            -sdk iphoneos \
            -configuration Release \
            -archivePath build/Baize.xcarchive \
            CODE_SIGNING_ALLOWED=NO

      - name: Export IPA
        run: |
          mkdir -p build/ipa/Payload
          cp -r build/Baize.xcarchive/Products/Applications/Baize.app build/ipa/Payload/
          cd build/ipa
          zip -r ../Baize.ipa Payload

      - name: Fakesign with ldid (TrollStore requires)
        run: |
          brew install ldid
          # ldid signing happens during build, or post-process
          ldid -SBaize/Baize/Baize.entitlements build/ipa/Payload/Baize.app/Baize

      - name: Upload IPA
        uses: actions/upload-artifact@v4
        with:
          name: Baize-IPA
          path: build/Baize.ipa
```

### 3.4 费用

| 计划 | 免费 macOS 分钟数 | 超出后价格 |
|------|-------------------|-----------|
| GitHub Free | 2000 分钟/月 (macOS 按 10x 计费 = 实际约 200 macOS 分钟) | $0.08/分钟 |
| GitHub Pro | 3000 分钟/月 | $0.08/分钟 |
| GitHub Team | 3000 分钟/月 | $0.08/分钟 |
| **公共仓库** | **无限免费** | $0 |

**关键**: macOS 分钟按 10 倍计费。一次 iOS 编译约 5-15 分钟（相当于 50-150 计费分钟）。对于开源项目（公共仓库），完全免费。

### 3.5 已知开源项目

多个开源项目使用 GitHub Actions 编译 iOS 应用：
- [Flutter Gallery](https://github.com/flutter/gallery) — Flutter 官方示例
- [Wikipedia iOS](https://github.com/wikimedia/wikipedia-ios) — 维基百科 iOS 版
- [Firefox iOS](https://github.com/nicklama/firefox-ios) — Firefox iOS 版
- [Signal iOS](https://github.com/nicklama/Signal-iOS) — Signal iOS 版

### 权威来源

- GitHub Actions macOS Runner 文档: https://docs.github.com/en/actions/using-github-actions/using-github-hosted-runners
- GitHub Actions 计费: https://docs.github.com/billing/reference/actions-runner-pricing

---

## 4. 本地代码执行沙箱

### 结论: **有限可行，需组合多种方案**

### 4.1 iOS 上能否运行本地代码编辑器/终端？

**可以，有多种先例**:

| 应用 | 类型 | 运行方式 | 语言支持 | App Store |
|------|------|----------|----------|-----------|
| **iSH** | Linux Shell 模拟器 | 用户态 x86 模拟（非 JIT） | Alpine Linux 包（sh, Python, git 等） | 是 |
| **a-Shell** | 原生终端 | ios_system 替换 libc 函数 | Python, Lua, JS, C/C++ (WASM) | 是 |
| **CodeApp** | IDE + 终端 | 嵌入式运行时 + Monaco Editor | Node.js 18, Python 3.9, C/C++, PHP, Java | 是 |
| **NewTerm** | 终端 | 越狱/TrollStore 环境直接 Shell | 系统命令 | 否（需越狱/TS） |

### 4.2 iSH 详细分析

**工作原理**: iSH 使用用户态 x86 模拟器，在 iOS 上运行 Alpine Linux 用户空间。它不使用 JIT（iOS 禁止），而是将 x86 指令翻译为 ARM 指令执行。

**能力**:
- 运行 Alpine Linux apk 包管理器
- 支持 Python、git、ssh、gcc 等（均为 x86 编译的 Alpine 包）
- 文件系统独立（iSH 内部文件系统，可通过 iOS File App 访问）
- 可运行 Node.js（但仅限 x86 版本，性能较差）

**限制**:
- 性能显著低于原生（x86 模拟开销约 5-10x）
- 无 JIT，动态语言性能差
- 不支持 ARM64 原生二进制
- 内存限制（iOS 后台限制）
- 与主应用沙箱隔离

**GitHub**: https://github.com/ish-app/ish

### 4.3 a-Shell 详细分析

**工作原理**: a-Shell 使用 `ios_system` 框架，将 Unix 命令重新实现为 iOS 原生函数调用。命令编译为 ARM64 原生格式。

**能力**:
- 原生 ARM64 性能
- 内置 Python、Lua、Perl、JavaScript (QuickJS)
- C/C++ 编译为 WebAssembly 运行（通过 wasmer）
- Vim 编辑器
- Apple Shortcuts 集成
- 多窗口支持
- iOS 文件系统集成（pickFolder）

**限制**:
- 不是完整的 Linux 环境（是 BSD 子集）
- Python 包仅支持纯 Python 包（无 C 扩展）
- Node.js 不支持（体积太大）
- C/C++ 只能编译为 WASM 执行，不是原生二进制
- 每个命令是独立的函数调用，不是真正的进程

**GitHub**: https://github.com/holzschu/a-Shell

### 4.4 CodeApp 详细分析（最接近目标）

**工作原理**: CodeApp 是一个类 VS Code 的 iPad IDE，嵌入 Monaco Editor + 本地运行时。

**能力**:
- **本地 Node.js 18.19.0** — 可运行 JS/TS 代码
- **本地 Python 3.9.2** — 可 pip install 纯 Python 包
- **C/C++ (Clang 14)** — 本地编译执行
- **PHP 8.3.2** — 本地运行
- **Java (OpenJDK 8)** — 本地运行
- Git 集成（clone, commit, push, fetch）
- 内置 Web Server（预览网页）
- Monaco Editor（VS Code 同款编辑器）
- 终端集成

**限制**:
- App Store 应用，受沙箱限制
- Node.js/Python 运行在沙箱内
- 文件系统访问仅限 App Container
- 无法安装需要编译的 npm/pip 包

**GitHub**: https://github.com/thebaselab/codeapp

### 4.5 iOS 上运行 Node.js / Python

| 方案 | Node.js | Python |
|------|---------|--------|
| **CodeApp** | 本地 18.19.0，沙箱内 | 本地 3.9.2，沙箱内 |
| **a-Shell** | 不支持 | 内置，纯 Python 包 |
| **iSH** | 可安装（x86 模拟，性能差） | 可安装（x86 模拟） |
| **TrollStore 应用** | **可嵌入 Node.js 静态编译版** | **可嵌入 Python 静态编译版** |
| **WASM 方案** | 不适用 | Pyodide (WASM Python) |

### 4.6 TrollStore 环境下的代码执行方案

TrollStore 去除沙箱后，**白泽智能体可采用以下方案**:

1. **嵌入 Node.js 静态编译版**: 将 Node.js 编译为 iOS arm64 静态二进制，打包进 App Bundle，通过 posix_spawn 执行
2. **嵌入 Python 静态编译版**: 使用 python-build-standalone 项目编译 iOS arm64 版
3. **WASM 运行时**: 嵌入 Wasmer/WasmEdge，运行 WASM 编译的代码
4. **直接 Swift 执行**: 对于简单脚本，用 Swift 实现 DSL 解释器

**推荐方案**: 嵌入 Node.js 静态二进制 + WASM 运行时

### 4.7 进程创建限制

| 操作 | 正常应用 | TrollStore 应用 |
|------|---------|----------------|
| `fork()` | 禁止 | 禁止（iOS 限制，非沙箱限制） |
| `posix_spawn()` | 仅沙箱内 | 可 spawn 任意二进制 |
| `exec()` | 仅沙箱内 | 可执行任意二进制 |
| Root 权限执行 | 不可能 | 通过 Root Helper 可实现 |
| JIT 编译 | 禁止 | 禁止（需 PPL bypass） |

**关键**: `fork()` 在 iOS 上对任何进程都是禁止的（包括 TrollStore 应用），这是内核级限制。只能使用 `posix_spawn()` 创建子进程。

### 权威来源

- iSH: https://ish.app/ | https://github.com/ish-app/ish
- a-Shell: https://holzschu.github.io/a-Shell_iOS/ | https://github.com/holzschu/a-Shell
- CodeApp: https://thebaselab.com/code/ | https://github.com/thebaselab/codeapp
- Apple Developer Forums - fork 限制: https://developer.apple.com/forums/thread/747499

---

## 5. 多模型 API 集成

### 结论: **完全可行，有多条路径**

### 5.1 各模型 API 格式对比

| 提供商 | API 格式 | 认证方式 | 流式支持 | 兼容 OpenAI 格式 |
|--------|----------|----------|----------|-----------------|
| **OpenAI** | Chat Completions | Bearer Token | SSE | 是（本身就是标准） |
| **Anthropic** | Messages API | x-api-key Header | SSE | 否（格式不同） |
| **Google Gemini** | GenerateContent | API Key Param | SSE | 部分兼容 |
| **Mistral** | Chat Completions | Bearer Token | SSE | 是（OpenAI 兼容） |
| **DeepSeek** | Chat Completions | Bearer Token | SSE | 是（OpenAI 兼容） |

**关键发现**: 大多数模型提供商已采用 OpenAI Chat Completions 格式作为事实标准。Anthropic 是主要例外。

### 5.2 统一多模型 SDK

#### 方案 A: OpenRouter（推荐）

**OpenRouter** 是一个 OpenAI 兼容的 API 网关，统一路由 300+ 模型。

**优势**:
- 单一 API endpoint，OpenAI 兼容格式
- 自动处理不同模型的 tokenizer 差异
- 提供商故障自动切换
- 成本优化路由
- 统一计费
- 仅增加约 30ms 延迟

**Swift 集成**:
```swift
// OpenRouter 使用 OpenAI 兼容格式，baseURL 不同即可
let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
var request = URLRequest(url: url)
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
request.setValue("baize/1.0", forHTTPHeaderField: "HTTP-Referer")
// 其余与 OpenAI API 完全相同
```

**已有 Swift 集成**: AIProxySwift 库已内置 OpenRouter 支持。

**限制**:
- 增加中间环节（延迟 +30ms，可靠性依赖 OpenRouter）
- 付费（模型原价 + 小额手续费）
- Anthropic 特有功能（如 tool_use）可能被弱化

#### 方案 B: SwiftAIKit（原生 Swift SDK）

**SwiftAIKit** 是一个轻量级 Swift 包，统一 OpenAI + Anthropic + Apple Intelligence。

**优势**:
- 纯 Swift 实现，零第三方依赖
- `AsyncThrowingStream` 实现流式输出
- JSON 模式支持
- Keychain 安全存储 API Key
- 运行时切换提供商

**限制**:
- 目前仅支持 OpenAI + Anthropic + Apple Intelligence
- 不支持 Google、Mistral、DeepSeek 等
- 要求 iOS 17+（不兼容 iOS 16.6.1）

#### 方案 C: 自建统一 API 层

直接基于 `URLSession` 实现 OpenAI Chat Completions 格式的客户端，对于不兼容的提供商（如 Anthropic）写适配层。

**优势**:
- 完全控制
- 无第三方依赖
- 可针对 iOS 16.6.1 优化

**推荐**: **方案 A (OpenRouter) + 方案 C (直接调用) 混合**

- 主路径使用 OpenRouter 简化开发
- 对需要低延迟或特定功能的模型（如 Anthropic tool_use），直接调用原生 API
- 核心网络层用 URLSession + AsyncStream 实现

### 5.3 Streaming SSE 在 iOS 上的实现

```swift
func streamChat(messages: [Message]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = URLSession.shared.bytesTask(with: request) { bytes in
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let json = line.dropFirst(6)
                    // 解析 SSE data，提取 content delta
                    continuation.yield(deltaContent)
                }
            }
            continuation.finish()
        }
        task.resume()
    }
}
```

**iOS 16.6.1 兼容**: `URLSession.bytesTask` 需要 iOS 15+，完全兼容。`AsyncThrowingStream` 需要 iOS 13+，完全兼容。

### 权威来源

- OpenRouter API 文档: https://openrouter.ai/docs/api/reference/overview
- SwiftAIKit: https://github.com/rouzbeh-abadi/SwiftAIKit
- AIProxySwift: https://github.com/lzell/AIProxySwift
- Natasha The Robot - Swift + OpenRouter: https://www.natashatherobot.com/p/swift-openrouter-api

---

## 6. 本地向量数据库/Embedding

### 结论: **完全可行，方案成熟**

### 6.1 SQLite 向量扩展

#### sqlite-vec（推荐）

**sqlite-vec** 是一个跨平台 SQLite 向量搜索扩展，专为嵌入式/移动端设计。

**iOS 支持**:
- 提供 Swift Package 依赖
- 通过 `sqlite3_load_extension` 加载
- 支持预编译 loadable library（XCFramework）

**核心特性**:
- **无需虚拟表** — 向量存储为普通表的 BLOB 列
- **无需预索引** — 零预处理时间，零成本更新
- **SIMD 加速** — ARM64 NEON 指令优化
- **TurboQuant 量化** — 2/3/4-bit 量化扫描，最多 38x 加速
- **6 种向量数据类型**: float32, float16, bfloat16, int8, uint8, 1bit
- **6 种距离度量**: L2, Squared L2, L1, Cosine, Dot Product, Hamming
- **极低内存**: 默认仅 30MB
- **离线工作**: 无需网络

**性能基准** (100万向量, 768维, DOT距离, k=10):
| 模式 | 存储 | 查询延迟 | 加速比 | Recall@10 |
|------|------|----------|--------|-----------|
| 暴力扫描 | 3.07 GB | 3248 ms | 1x | 1.00 |
| TurboQuant 4-bit | 396 MB | 218 ms | 14.92x | 0.84 |
| TurboQuant 3-bit | 300 MB | 188 ms | 9.19x | 0.74 |
| TurboQuant 2-bit | 204 MB | 85 ms | 38.27x | 0.48 |

**GitHub**: https://github.com/asg017/sqlite-vec

#### SQLite-Vector（新版）

**SQLite-Vector** 是 sqlite-vec 的新一代版本（同作者 alexgarcia），进一步增强。

- 完整 iOS 支持（Swift Package）
- Xcode 26 兼容
- 更多优化

**GitHub**: https://github.com/sqliteai/sqlite-vector

### 6.2 iOS 原生 Embedding 方案

#### 方案 A: CoreML + all-MiniLM-L6-v2（推荐）

已有开源项目将 `all-MiniLM-L6-v2` 转换为 CoreML 模型:

- **模型大小**: ~22MB (CoreML .mlmodel)
- **向量维度**: 384
- **推理速度**: iPad Pro M1 上约 10-20ms/句
- **Swift 集成**: MiniLMTokenizer + CoreML prediction

```swift
let tokenizer = try MiniLMTokenizer(vocabURL: vocabURL)
let tokens = tokenizer.encode("Hello world")
let embeddings = try model.prediction(
    inputIds: tokens.inputIds,
    attentionMask: tokens.attentionMask
)
```

**GitHub**: https://github.com/Abhishek6353/AllMiniLML6V2-coreml

#### 方案 B: Apple NaturalLanguage 框架

iOS 内置的 NaturalLanguage 框架提供文本嵌入功能:

```swift
import NaturalLanguage

let embedding = NLEmbedding.sentenceEmbedding(for: .english)
let vector = embedding?.vector(for: "Hello world")
// 维度: 512 (GloVe-based)
```

**优势**: 无需额外模型文件，系统内置
**限制**: 质量低于 MiniLM，512 维，基于 GloVe 而非 Transformer

#### 方案 C: 远程 Embedding API

调用 OpenAI `/v1/embeddings` 或其他云端 API:
- 优势: 最高质量
- 劣势: 需要网络，有延迟和成本

### 6.3 推荐方案

**混合方案**: CoreML 本地 Embedding (all-MiniLM-L6-v2) + sqlite-vec 向量搜索

- 本地 embedding 保证离线可用和低延迟
- sqlite-vec 提供高效向量搜索
- 384 维 + TurboQuant 4-bit 在 M1 上性能极佳
- 对于需要更高质量的场景，可选远程 embedding API

### 权威来源

- sqlite-vec: https://github.com/asg017/sqlite-vec
- SQLite-Vector: https://github.com/sqliteai/sqlite-vector
- all-MiniLM-L6-v2 CoreML: https://github.com/Abhishek6353/AllMiniLML6V2-coreml
- Apple NaturalLanguage: https://developer.apple.com/documentation/naturallanguage

---

## 7. 竞品分析

### 7.1 主流编程智能体的 iOS 支持情况

| 产品 | iOS 版本 | 说明 |
|------|----------|------|
| **Cursor** | 无 | 桌面端 (Electron)，无 iOS 计划 |
| **Windsurf** | 无 | 桌面端 (Electron)，无 iOS 计划 |
| **Claude Code** | 无 | 终端 CLI 工具，无 iOS 版本 |
| **GitHub Copilot** | 无独立 iOS 应用 | 仅有 VS Code 扩展 |
| **Codeium** | 无 | 桌面 IDE 插件 |
| **Aider** | 无 | 终端 CLI 工具 |

**结论**: 目前**没有任何主流编程智能体有 iOS/iPadOS 版本**。这是一个空白市场。

### 7.2 iOS 代码编辑器应用

| 应用 | 类型 | AI 集成 | 代码执行 | 开源 |
|------|------|---------|----------|------|
| **CodeApp** | IDE | 无 | 本地 Node.js/Python/C | 是 (MIT) |
| **a-Shell** | 终端 | 无 | Python/Lua/JS/C(WASM) | 是 (FreeBSD) |
| **iSH** | Linux Shell | 无 | Alpine Linux 包 | 是 (GPL) |
| **Pythonista** | Python IDE | 无 | 本地 Python | 否 |
| **Carnets** | Jupyter | 无 | 本地 Python/Jupyter | 否 |
| **Textastic** | 代码编辑器 | 无 | 无执行 | 否 |
**Koder** | 代码编辑器 | 无 | 无执行 | 否 |

### 7.3 iOS AI 辅助编程相关

| 应用/项目 | 类型 | 说明 |
|-----------|------|------|
| **Xcode + Swift Assist** | 官方 IDE AI | 仅 Mac，Xcode 26+ |
| **GitHub Copilot for VS Code** | Web | 需 VS Code Web，非本地 |
| **ChatGPT iOS** | 聊天 | 可讨论代码，无编辑器/执行 |
| **Claude iOS** | 聊天 | 可讨论代码，无编辑器/执行 |

### 7.4 开源 iOS code editor + AI 项目

**没有找到**任何开源的 iOS 代码编辑器 + AI 编程助手的组合项目。最接近的是:

1. **CodeApp** — 有完整的代码编辑器和本地执行环境，但无 AI
2. **a-Shell** — 有终端和编程语言，但无 AI
3. **OpenCat** — iOS ChatGPT 客户端（非编程专用）

### 竞争分析结论

**白泽 iOS 编程智能体将是一个首创产品**，在以下方面没有直接竞品:
- iOS 上 AI + 代码编辑 + 本地执行的组合
- 移动端编程智能体 (Agentic Coding) 概念
- TrollStore 特权增强的编程工具

最接近的参照是 **CodeApp**（编辑器+执行）+ **ChatGPT iOS**（AI 聊天），但两者未结合。

---

## 8. 综合评估与建议

### 8.1 各模块可行性总结

| 模块 | 可行性 | 难度 | 关键风险 |
|------|--------|------|----------|
| Swift + SwiftUI 技术栈 | 完全可行 | 中 | 需 Mac/Xcode 开发 |
| TrollStore 免签安装 | 完全可行 | 低 | iOS 更新可能破坏；JIT 不可用 |
| GitHub Actions CI/CD | 完全可行 | 低 | macOS 分钟费用；公共仓库免费 |
| 本地代码执行 | 有限可行 | 高 | fork 禁止；JIT 禁止；需嵌入运行时 |
| 多模型 API 集成 | 完全可行 | 中 | API 格式差异；网络依赖 |
| 本地向量数据库 | 完全可行 | 低 | sqlite-vec 方案成熟 |
| 竞品 | 无竞品 | — | 空白市场 |

### 8.2 核心技术挑战

1. **代码执行沙箱** (最大挑战)
   - iOS 禁止 fork()，只能 posix_spawn()
   - JIT 编译禁止，影响 Node.js/Python 性能
   - 解决方案: 嵌入静态编译的 Node.js/Python 二进制 + WASM 运行时

2. **代码编辑器** (中等挑战)
   - iOS 没有原生代码编辑器组件
   - 解决方案: WKWebView + Monaco Editor（CodeApp 方案）或自建 TextKit 编辑器

3. **TrollStore 限制** (低挑战)
   - 无法后台常驻（无 Launch Daemon）
   - 图标缓存刷新后需重新注册
   - 解决方案: 用户手动操作即可，影响不大

### 8.3 推荐架构

```
┌─────────────────────────────────────────────────────┐
│                   白泽 iOS App                       │
│  (SwiftUI + WKWebView for Monaco Editor)            │
├──────────────┬──────────────┬───────────────────────┤
│   UI Layer   │  Agent Core  │   System Layer        │
│              │              │                        │
│ - Monaco     │ - LLM API    │ - posix_spawn()       │
│   Editor     │   Client     │ - Node.js binary      │
│ - Chat UI    │ - Tool       │ - Python binary       │
│ - File       │   Executor   │ - WASM Runtime        │
│   Browser    │ - Memory     │ - sqlite-vec          │
│ - Terminal   │   (Vector    │ - CoreML Embedding    │
│   Emulator   │    Store)    │ - FileManager         │
│              │ - Planning   │ - Root Helper         │
│              │   Engine     │                        │
├──────────────┴──────────────┴───────────────────────┤
│              TrollStore Entitlements                 │
│  no-sandbox | platform-application | persona-mgmt   │
├─────────────────────────────────────────────────────┤
│              iPad Pro M1 + iOS 16.6.1               │
└─────────────────────────────────────────────────────┘
```

### 8.4 开发路径建议

**Phase 1 — MVP（8-12 周）**
- SwiftUI 壳应用 + Monaco Editor (WKWebView)
- OpenAI API 集成（SSE 流式）
- 基本文件浏览和编辑
- TrollStore 安装验证

**Phase 2 — 代码执行（4-6 周）**
- 嵌入 Node.js 静态二进制
- 终端 UI 实现
- Tool Executor 框架

**Phase 3 — 智能体能力（6-8 周）**
- 多模型支持（OpenRouter）
- 本地向量数据库 + CoreML Embedding
- Agent Loop（Plan → Execute → Verify）

**Phase 4 — 高级功能（持续）**
- Git 集成
- 多文件上下文管理
- WASM 代码执行
- Root Helper 特权操作

### 8.5 风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| Apple 修复 CoreTrust bug | 低 | iOS 16.6.1 已停止更新；不升级即可 |
| TrollStore 被 Apple 封杀 | 低 | 同上，停留在 16.6.1 |
| JIT 限制影响代码执行 | 中 | 使用解释模式 + WASM；对大部分场景够用 |
| 代码编辑器性能 | 中 | Monaco Editor 在 WKWebView 中性能可接受 |
| App 体积过大 | 中 | Node.js binary 约 40-60MB；可按需下载 |
| macOS runner 费用 | 低 | 公共仓库免费；私有仓库费用可控 |

---

## 附录: 关键开源项目清单

| 项目 | 用途 | 地址 |
|------|------|------|
| TrollStore | 免签安装 | https://github.com/opa334/TrollStore |
| TrollInstallerX | 安装工具 | https://github.com/alfiecg24/TrollInstallerX |
| iSH | Linux Shell | https://github.com/ish-app/ish |
| a-Shell | 终端 | https://github.com/holzschu/a-Shell |
| CodeApp | IDE 参考 | https://github.com/thebaselab/codeapp |
| sqlite-vec | 向量搜索 | https://github.com/asg017/sqlite-vec |
| SQLite-Vector | 向量搜索(新) | https://github.com/sqliteai/sqlite-vector |
| AllMiniLML6V2-coreml | 本地 Embedding | https://github.com/Abhishek6353/AllMiniLML6V2-coreml |
| SwiftAIKit | 多模型 SDK | https://github.com/rouzbeh-abadi/SwiftAIKit |
| AIProxySwift | OpenRouter 集成 | https://github.com/lzell/AIProxySwift |
| Monaco Editor | 代码编辑器 | https://github.com/microsoft/monaco-editor |
