# 白泽 (Baize) — AI 继承者交接文档 v17

> **给下一位 AI 的话**：v16 之后完成了 CI 编译修复（13+1 个错误）+ 全量代码审查（141 文件读完，57 个问题）。现在 CI 能过、IPA 能打包，但 3 个 P0 问题未修，App 未真机验证。不要再猜，看证据。
>
> **严格按文档指示操作，不要自己瞎猜；不确定的就去核验、查清。**
>
> **生成时间**: 2026-06-23 11:19 | **版本**: v17（替代 v16，因 v16 后完成了编译修复 + 全量审查）
> **前任 AI**: 齐活林（交付总监）+ 软件开发团队 SOP
> **本次会话核心**: 接手 v16 → 修 CI 编译错误 → 替换 cacert.pem → 全量代码审查

---

## 0. TL;DR — 最重要的事先说

1. **项目位置**: `D:\2\WorkBuddy\2026-06-21-18-14-27\baize`
2. **GitHub**: https://github.com/Da-AiXZ/BaiZe（分支 `main`）
3. **最新 commit**: `6c021a8` chore(binaries): replace cacert.pem placeholder with Mozilla CA bundle
4. **CI 状态**: ✅ #153 通过（commit 6c021a8），IPA 已生成 58.2MB，可下载安装
5. **Token**: 已嵌入 git remote URL，不要写明文，GitHub secret scanning 会拒绝 push
6. **当前状态**: ✅ 编译通过 + IPA 可打包；⚠️ 3 个 P0 问题未修；⚠️ 未真机验证
7. **积分警告**: 用户积分紧张，每做一步就 commit+push，随时可能被中断
8. **下一步首要任务**: 修 3 个 P0 问题（详见 `BAIZE_AUDIT_V1.md`），然后真机验证

---

## 1. 项目身份与运行环境

| 字段 | 值 |
|------|------|
| **名称** | 白泽 (Baize) — iOS 本地编程智能体 |
| **类比** | 像 Claude Code / Codex，但跑在 iPad Pro M1 本地 |
| **运行环境** | iPad Pro 2021 M1, iOS 16.6.1, 通过 TrollStore 免签安装 |
| **构建方式** | GitHub Actions CI (macos-14 runner, Xcode 15.4) → 编译 IPA → ldid fakesign → 下载安装 |
| **技术栈** | Swift 6 + SwiftUI \| libgit2 C API \| nodejs-mobile (--jitless) \| CPython 3.13 \| ios_system \| Monaco Editor (WKWebView) |
| **GitHub 仓库** | https://github.com/Da-AiXZ/BaiZe |
| **分支** | main |
| **本地路径** | `D:\2\WorkBuddy\2026-06-21-18-14-27\baize` |
| **GitHub Token** | `<见 git remote URL，不要写明文>` |
| **最新 commit** | `6c021a8` |
| **最新通过 CI** | #153（commit 6c021a8） |
| **IPA Artifact** | `Baize-IPA`，58.2 MB，artifact id=7804750549（CI #152 的，#153 的需重新查） |
| **IPA 目标** | iOS 16.0+, arm64, ldid fakesign, TrollStore 安装 |

### Token 获取方式（严禁写明文）

```bash
git -C "D:\2\WorkBuddy\2026-06-21-18-14-27\baize" remote -v
```

⚠️ **历史教训**: 交接文档里曾写明文 token，结果 GitHub secret scanning 拒绝 push。必须只写 `<见 git remote>`。

---

## 2. 本次会话发生了什么（时间线）

### 阶段一：接手 v16 + CI 编译修复（04:34–05:00）

- 读取 v16 交接文档，核验项目状态
- 下载 CI #150 失败日志，提取 13 个 ❌ 编译错误
- 创建团队 `software-bugfix-ci-compile`（BugFix 快捷路径）
- 工程师寇豆码修复 7 处源码（6 文件），IS_PASS: YES
- commit `fd9d3e5`，触发 CI #151 → 仍有 1 个错误（LockedBox 双层 optional）
- commit `5bf5c15`，单行修复，触发 CI #152 → ✅ 通过，IPA 生成

### 阶段二：占位二进制调研 + cacert.pem 替换（10:16–10:35）

- 核验 `Resources/binaries/` 三个占位文件状态：
  - `git`：0 字节
  - `mkdir`：0 字节
  - `cacert.pem`：115 字节占位
- 下载 Mozilla CA 证书包（189KB）替换 cacert.pem，commit `6c021a8`
- 调研 git 二进制方案：holzschu/a-Shell-commands 是 wasm 格式不能用，shell-ios 仓库 404
- 发现 libgit2 从 0.23 支持 `GIT_OPT_SET_SSL_CERT_LOCATIONS` API，v15 架构师漏掉了
- 给用户三个方案（A: CI 编译 git / B: 改回 libgit2+CA / C: 先不管 git 远程）

### 阶段三：全量代码审查（10:48–11:19）

- 用户极度不满，要求"全部全部代码审查一遍，不是只看部分"
- 创建团队 `software-baize-full-audit`
- QA 严过关读模块 1-6+8（100 文件）
- 工程师寇豆码读模块 7 剩余 31 个 View 文件
- 全部 141 文件 Read 读完，发现 57 个问题
- 问题清单落盘到 `BAIZE_AUDIT_V1.md`

---

## 3. CI 编译修复详情（commit fd9d3e5 + 5bf5c15）

### 修复 1：GitService.swift 补声明缺失属性（解决 8 个错误）
- 在 `gitShellService` 属性前插入 `repositoryPath` 和 `keychainService` 声明

### 修复 2：GitService.swift 方法重命名（解决 1 个错误）
- `gitShellService()` → `getGitShellService()`（避免与属性同名冲突）

### 修复 3：ExecuteCommandTool.swift 调用点改名
- L84 `gitService.gitShellService()` → `gitService.getGitShellService()`

### 修复 4：FileSystemService.swift LockedBox 线程安全（解决 2 个错误）
- 新增嵌套类 `LockedBox<T>: @unchecked Sendable`（NSLock 包装）
- `runSync` 改用 `box.set()` / `box.get()`
- **CI #151 暴露的后续 bug**：`LockedBox<Result<T, Error>?>` 导致双层 optional，`finalResult.get()` 报错
- **CI #152 修复**：改为 `LockedBox<Result<T, Error>>`（非 optional）

### 修复 5：PlatformFileSystem.swift 闭包捕获 self（解决 1 个错误）
- L343 提取局部变量 `let strategyName = currentStrategy().rawValue`

### 修复 6：SkillTool.swift 作用域错误（解决 1 个错误）
- `availableNames` 移到正确的 guard scope 内

### 修复 7：TavilySearchProvider.swift 删除未使用变量（解决 1 个错误）
- 删除 `let score = item["score"] as? Double ?? 0.0`

---

## 4. 全量代码审查结果（57 个问题）

### 问题清单文件
**`BAIZE_AUDIT_V1.md`** — 完整 57 个问题清单，按 P0/P1/P2/P3 分级，每个问题含文件:行号:描述:建议

### 3 个 P0 问题（必须修复）

| # | 文件 | 问题 | 状态 |
|---|------|------|------|
| P0-1 | FileSystemService.swift:170 | 主线程 DispatchSemaphore.wait() 阻塞，PlatformFileSystem actor 忙时卡死 UI | ❌ 未修 |
| P0-2 | GitShellService.swift | git 二进制 0 字节，Git HTTPS 远程 100% 失败 | ❌ 未修 |
| P0-3 | ProjectContext.swift:57 | updateRootPath 创建新 FileSystemService 破坏共享实例 | ❌ 未修 |

### 功能可用性判断（基于代码证据）

| 功能 | 状态 | 依据 |
|------|------|------|
| App 启动 | ✅ 大概率能启动 | BaizeApp.init 依赖注入链完整 |
| Agent Loop | ✅ 可用 | while-true + 工具调用 + 上下文压缩 |
| 权限系统 | ✅ 可用 | 5 模式 + PlanMode 硬拦截，17 个测试覆盖 |
| Git 本地操作 | ✅ 可用 | libgit2 封装正确，defer 释放 C 指针 |
| **Git HTTPS 远程** | ❌ **不可用** | git 二进制 0 字节 |
| 文件系统 | ⚠️ 有风险 | runSync semaphore 可能阻塞主线程 |
| Node.js | ⚠️ 未验证 | 依赖 NodeMobile.framework 链接 |
| Python | ⚠️ 未验证 | 依赖 Python.xcframework 链接 |
| MCP/Skills/Memory | ✅ 可用 | actor 隔离 + JSONL 持久化 |
| 命令执行 | ⚠️ exitCode 恒 0 | ios_popen 限制 |

---

## 5. v15 架构决策的实际情况

### Q1 Git HTTPS — 架构师方案有漏洞

**v15 架构师选的方案**：shell out git 二进制 + `GIT_SSL_CAINFO` 指定 CA 证书

**问题**：
1. git 二进制需要交叉编译 iOS arm64 静态二进制（依赖 zlib/openssl/curl），用户没 Mac 做不了
2. 架构师**漏掉了** libgit2 从 0.23 就支持的 `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS)` API
3. 代码里 `git_libgit2_opts` 一次都没调用过

**iOS 上 OpenSSL 无法访问系统 Keychain CA 证书是真的**（iOS 平台硬限制，StackOverflow 有确切证据），但"必须 shell out git 二进制"是错的。

**给用户的三个方案**：
- 方案 A：CI 编译 git 二进制（v15 原方案，复杂，CI +15-20 分钟，可能失败）
- 方案 B（推荐）：改回 libgit2 + `GIT_OPT_SET_SSL_CERT_LOCATIONS` 指向 cacert.pem（改动小，无需编译 git）
- 方案 C：先不管 git 远程，让 IPA 本地功能能用

**用户未决策**，P0-2 待定。

### Q2-Q6 其他决策
- Q2 子 Agent 隔离：✅ 已实现，SubAgentContext 独立 FS/权限/会话
- Q3 Skills fork 执行：✅ 已实现，SkillExecutor 在子 Agent 中执行
- Q4 Memory stopHooks：✅ 已实现，JSONL + 关键词匹配
- Q5 文件系统统一：✅ 已实现，PlatformFileSystem 三策略降级
- Q6 权限引擎统一：✅ 已实现，5 模式 + ToolRegistry 硬拦截

---

## 6. Commit 历史（必读）

```
6c021a8 chore(binaries): replace cacert.pem placeholder with Mozilla CA bundle  ← 最新
5bf5c15 fix(build): LockedBox optional double-wrap (CI #151)
fd9d3e5 fix(build): resolve 13 CI compile errors from v15 refactor
c730e3f docs: complete v16 handoff with all sections from V12-V15
9055111 docs: v16 handoff after v15 refactor completion
c2697d8 fix(t05): MemoryStore baseDir path
8c45091 test(t05): sub-agent isolation, skills, memory
2a7e4b3 refactor(t05): memory platform filesystem + stop hooks + append file
9541d60 fix(t03): quote-aware git command parsing and rename directory helper
83c15e1 test(t03): git HTTPS shell transport tests
cdb44fb refactor(t03): git HTTPS shell transport
0a69d79 test(t02): file system unification tests
1f08671 fix(t02): replace remaining ensureDirectoryExists with createDirectory
7d1eef4 refactor(t02): unify file system access
324a5e9 fix(t04): acceptEdits mode bypasses needsPermission for file edits
55aa2d2 fix(t04): session approval and acceptEdits logic
ff60f72 refactor(phase1): unify permission engine
37e51ad refactor(t01): platform infrastructure and file system interfaces
d00e029 docs: v15 architecture design
```

---

## 7. 你的优先任务清单（按顺序）

### P0：修 3 个 P0 问题（见 BAIZE_AUDIT_V1.md）

#### P0-1 FileSystemService 主线程阻塞
- **文件**: `Baize/Baize/Infrastructure/FileSystemService.swift:170-191`
- **修复方向**: EditorState 的文件操作改为 async，或用缓存避免同步等待 actor
- **风险**: 改动面大，EditorState 的同步调用点很多

#### P0-2 GitShellService 空 git 二进制
- **文件**: `Baize/Baize/Services/GitShellService.swift` + `Baize/Baize/Services/GitService.swift`
- **决策**: 方案 A（CI 编译 git）vs 方案 B（改回 libgit2 + CA 路径）
- **推荐方案 B**：在 BaizeApp 启动时调 `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, BaizeBinary.caBundlePath, nil)`，GitService 的 fetch/pull/push/clone 改回 libgit2 实现，删除 certificate_check 回调
- **需用户确认方案后再动手**

#### P0-3 ProjectContext 破坏共享实例
- **文件**: `Baize/Baize/Agent/ProjectContext.swift:57`
- **修复**: `FileSystemService(rootPath: path)` → `fileSystemService.updateRootPath(path)`
- **风险**: 小，改动 1 行

### P0：真机验证
- 下载 CI #153 的 IPA（artifact id 需重新查）
- 装到 TrollStore 试启动
- 如果启动崩溃，看崩溃日志定位
- 如果启动成功，逐个功能点测试

### P1：修 6 个 P1 问题
- AgentLoop 工具调用顺序、exitCode 恒 0、KeychainService 重复创建、强制解包 ×2、PythonSpawnStrategy workingDir

### P2：修 11 个 P2 问题
- PlanModeState continuation、PosixSpawn 超时、Keychain 明文、路径不一致、ChatInputView 竞态等

### P3：修 37 个 P3 问题（代码质量，不阻塞）

---

## 8. CI/CD 管道速查

### 工作流文件
`.github/workflows/build.yml`

### CI 步骤顺序
```
Checkout → Select Xcode 15.4 → Install tools (brew ldid xcodegen + gem xcpretty)
→ Cache SPM → Configure git HTTPS → xcodegen generate
→ Resolve SPM → Patch ios_system xcframeworks → Download Runtime binaries
→ Build libgit2 xcframework → Patch repo-local xcframeworks
→ Download Monaco Editor → xcodebuild archive
→ build-ipa.sh → verify-ipa.sh → Upload IPA artifact
```

### 构建关键参数
- **Runner**: `macos-14` + Xcode 15.4
- **SDK**: `iphoneos`, arch `arm64`
- **签名**: ldid fakesign（适合 TrollStore）
- **部署目标**: iOS 16.0
- **IPA 输出**: `output/Baize.ipa`

### 如何查看 CI 状态（Windows Git Bash）

```bash
export GH_TOKEN="<见 git remote URL>"

# 最近 5 次 CI 运行
curl -s -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs?per_page=5" \
  | python -c "import json,sys; [print(f\"#{r['run_number']} | {r['status']}/{r['conclusion']} | {r['head_sha'][:7]}\") for r in json.load(sys.stdin)['workflow_runs']]"

# 下载 CI 日志 zip
RUN_ID=<run_id>
curl -sL -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/repos/Da-AiXZ/BaiZe/actions/runs/${RUN_ID}/logs" \
  -o ci-logs.zip
unzip ci-logs.zip -d ci-logs

# 提取编译错误
grep -nE "❌ |error:|BUILD FAILED" "ci-logs/Build & Package IPA (XcodeGen)/15_Build Archive (xcodebuild).txt" | grep -v "this is an error in Swift 6"
```

---

## 9. 已知限制与风险

1. **3 个 P0 问题未修**：FileSystemService 主线程阻塞、GitShellService 空 git 二进制、ProjectContext 破坏共享实例。详见 `BAIZE_AUDIT_V1.md`
2. **未真机验证**：CI #153 编译通过 + IPA 打包成功，但 App 从没在真机上跑过。编译通过 ≠ 能启动
3. **Git HTTPS 远程 100% 不可用**：git 二进制 0 字节，GitShellService 调用必然抛错。本地 Git 操作不受影响
4. **占位二进制**：`Resources/binaries/git` 和 `mkdir` 仍是 0 字节。cacert.pem 已替换为真实 Mozilla CA 包（189KB）
5. **Windows 环境限制**：当前开发环境无 Swift/Xcode，无法本地编译。所有编译验证依赖 CI
6. **v15 架构决策遗留**：GitShellService shell out git 方案在无 Mac 环境下走不通，需决策方案 A 或 B
7. **57 个审查问题**：3 P0 + 6 P1 + 11 P2 + 37 P3，详见 `BAIZE_AUDIT_V1.md`

---

## 10. 踩坑记录（本次会话新增）

1. **Swift 6 严格并发检查把 warning 升级为 error**：captured var、未使用变量、actor-isolated autoclosure 都会被拒。CI #150 的 13 个错误里大部分是这类
2. **LockedBox 双层 optional 陷阱**：`LockedBox<Result<T, Error>?>` 的泛型 T = `Result<X, Error>?`，`box.get()` 返回 `Result<X, Error>??`，guard let 只解一层，`.get()` 在 optional 上调用报错。CI #151 暴露，改为 `LockedBox<Result<T, Error>>` 解决
3. **方法名与属性名同名冲突**：`func gitShellService()` 与 `let gitShellService: GitShellService` 同名，Swift 报 "invalid redeclaration"，即使一个是 method 一个是 property
4. **QA 审查会偷懒**：第一次 QA 审查说"View 文件崩溃风险低不需要读"，被用户骂后承认读不完，拆分给工程师才读完。不要信任"风险低"这种猜测，必须用 Read 工具读完每个文件
5. **CI 轮询经验**：CI #152 跑 9 分钟成功，用 3 分钟间隔轮询 API 足够。不要更频繁，浪费 API 调用
6. **libgit2 的 `GIT_OPT_SET_SSL_CERT_LOCATIONS` API**：v15 架构师漏掉了这个 API，导致选了 shell out git 二进制的复杂方案。libgit2 从 0.23 就支持，白泽用 1.3.1，完全可用

---

## 11. 关键文件速查表

| 模块 | 必读文件 |
|------|----------|
| **全量审查问题清单** | `BAIZE_AUDIT_V1.md` ← **本次新增，57 个问题** |
| 架构 | `baize/docs/architecture-v15.md` |
| 权限 | `Baize/Baize/Agent/PermissionEngine.swift` |
| 文件系统 | `Baize/Baize/Infrastructure/PlatformFileSystem.swift` |
| 文件系统策略 | `Baize/Baize/Infrastructure/PlatformFileSystemStrategy.swift` |
| 文件服务（P0-1） | `Baize/Baize/Infrastructure/FileSystemService.swift` |
| Git 本地 | `Baize/Baize/Services/GitService.swift` |
| Git 远程（P0-2） | `Baize/Baize/Services/GitShellService.swift` |
| 子 Agent | `Baize/Baize/Agent/SubAgent/SubAgentContext.swift` |
| Skills | `Baize/Baize/Agent/Skills/SkillExecutor.swift` |
| Memory | `Baize/Baize/Agent/Memory/MemoryStore.swift` |
| ProjectContext（P0-3） | `Baize/Baize/Agent/ProjectContext.swift` |
| 启动入口 | `Baize/Baize/App/BaizeApp.swift` |
| 常量 | `Baize/Baize/Utils/Constants.swift` |
| 项目配置 | `project.yml` |
| CI | `.github/workflows/build.yml` |

---

## 12. 如果你只剩很少积分

只做以下三件事，其他留给用户：
1. 修 P0-3（ProjectContext 一行改动）+ P0-1（FileSystemService 改 async，最小改动）
2. 让用户决策 P0-2 方案 A 还是 B，不要自己定
3. commit+push 后结束

不要开始全量修复 57 个问题。

---

## 13. 用户情绪与沟通要点

本次会话用户极度不满，原话："做个项目怎么问题这么多，做前做的这么好听，真正用起来这么多问题"。沟通要点：
1. **不要粉饰**：编译通过 ≠ 功能能用，如实汇报状态
2. **不要猜**：不确定就去核验，用证据说话
3. **不要偷工减料**：审查要全量读完，不要"风险低"就跳过
4. **直来直去**：用户偏好直接回答，不要绕弯子
5. **积分有限**：每步都 commit+push，随时可能被中断

---

*本交接文档基于 v16 交接文档 + 本次会话的 CI 编译修复 + cacert.pem 替换 + 全量代码审查（141 文件读完，57 个问题）。所有问题清单见 `BAIZE_AUDIT_V1.md`。*
