# 白泽 Git 暂存 zlib 阻塞问题 — 技术评审报告

> 评审人：架构师 高见远 | 日期：2026-06-19 | 评审对象：Git 暂存功能 zlib 阻塞问题修复方案

## 问题根因（已确认）

白泽用 light-tech/LibGit2-On-iOS v1.3.1 的预编译 libgit2.xcframework（静态库 .a）。该预编译库的 build script（`build-libgit2-framework.sh`）在 `build_libgit2()` 函数的 cmake 参数里**完全没有处理 zlib**——既没 `-DUSE_BUNDLED_ZLIB=ON`，也没显式指定 zlib。

libgit2 v1.3.1 的 CMakeLists.txt 中：

```cmake
OPTION(USE_BUNDLED_ZLIB "Use the bundled version of zlib. Can be set to one of
      Bundled(ON)/Chromium. The Chromium option requires a x86_64 processor
      with SSE4.2 and CLMUL" OFF)
```

- 默认 OFF → 走 `find_package(ZLIB)` 使用系统 zlib
- 设为 ON → libgit2 使用自带 `deps/zlib/` 源码静态编译，直接链入 libgit2.a，完全不碰系统 libz

light-tech 脚本走默认 OFF，于是：
- 编译时：用 iPhone SDK 的 zlib.h
- 运行时：链接 iOS 16.6.1 系统的 libz.tbd
- 结果：在 TrollStore no-sandbox 环境下，`deflateInit_` 失败，libgit2 报 "failed to initialize zlib"

`git_index_add` / `git_index_write_tree` / `git_commit_create` 等需要写 loose object 的操作全部因此失败。第七轮尝试用系统 zlib `compress2` + CommonCrypto `CC_SHA1` 手动构建 git loose objects 绕过，CI 通过但真机仍然失败。

---

## 方案 A 评审：自编译 libgit2 + USE_BUNDLED_ZLIB

### 可行性 — ✅ 完全可行

1. **USE_BUNDLED_ZLIB 选项已确认存在**：直接阅读 libgit2 v1.3.1 源码 CMakeLists.txt 确认。
2. **light-tech 构建脚本缺陷已确认**：build_libgit2() 的 cmake 参数完全没有 USE_BUNDLED_ZLIB。
3. **CI 编译可行性**：macos-14 runner 有 Xcode 15.4 + cmake，原脚本已做交叉编译。白泽只需 iphoneos arm64 一个 slice，预估编译时间 10-15 分钟，CI timeout 45 分钟充裕。建议缓存编译产物。

### 工作量评估

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `scripts/build-libgit2.sh` | 新建 | ~150行（fork light-tech 脚本，精简为单平台，加 USE_BUNDLED_ZLIB=ON） |
| `.github/workflows/build.yml` | 修改 | ~5行（download 步骤替换为 build 步骤） |
| `GitService.swift` | 修改 | **删除~400行**第七轮 bypass 代码，恢复~50行干净 libgit2 调用 |
| `Baize-Bridging-Header.h` | 修改 | 删除2行（zlib.h + CommonDigest.h） |
| `project.yml` | 修改 | 删除1行（libz.tbd） |

Swift 侧改动主要是**删除**第七轮的临时 bypass 代码（sha1Hex, zlibCompress, writeLooseObject, manualStageFile, manualStageAll, manualCommit, warmupIndex, testZlib），stage/stageAll/commit 恢复为干净的 libgit2 调用。代码量反而减少。

### 风险评估

| 风险点 | 概率 | 缓解 |
|--------|------|------|
| deps/zlib 源码不存在 | 极低 | 选项定义在 CMakeLists.txt 中必然有对应源码 |
| Xcode 15.4 编译兼容性 | 低 | cmake 交叉编译是标准流程，clang 向后兼容 |
| CI 编译时间过长 | 低 | 精简单平台~15min，加缓存后<1min |
| libpcre 编译问题 | 低 | 可用 -DREGEX_BACKEND=builtin 替代 |

### 对铁律的影响

**不违反任何铁律（0/10）。** 完全不碰 Node.js，不删 patch-xcframeworks.sh，不影响任何其他铁律。

---

## 方案 B 评审：isomorphic-git 纯 JS 方案

### 可行性

- **nodejs-mobile 版本**：v18.20.4，充分支持 isomorphic-git（最低 Node 10）
- **CommonJS**：✅ 支持 require()
- **API 支持**：init ✅, status ✅, add ✅, commit ✅, push ✅, log ✅, branch ✅, checkout ✅
- **diff**：❌ **isomorphic-git 没有 diff 函数**（59个命令中无 diff），需自定义实现
- **Push 认证**：onAuth 回调返回 {username: token}，兼容现有 token 方式
- **文件系统**：使用原生 require('fs')，no-sandbox 下理论上可访问 /var/mobile/Documents/Baize/，但需真机验证

### npm 打包方案

在 Resources/nodejs/ 下 `npm install --production isomorphic-git`，整个 node_modules 随 folder resource 打包进 App Bundle。体积影响 ~1-2MB。

### GitService 重写工作量

- GitService.swift **完全重写**：actor libgit2 C API (~1400行) → HTTP client (~800行)
- bootstrap.js **重大修改**：新增 require('isomorphic-git') + /git 端点 (+~80行)
- diff 功能需自定义实现（statusMatrix + readBlob + JS diff 库）
- GitViewModel.swift 需适配新 API

### 对铁律的影响

**违反铁律 #7（不动 Node.js 代码）**——必须修改 bootstrap.js。

深度分析：
1. require('isomorphic-git') 在 Node.js 启动时执行——如果 isomorphic-git 有初始化错误，**整个 Node.js 进程无法启动**
2. node_start() 整个 App 生命周期只能调用一次，Node.js 崩溃后**不可恢复**
3. Node.js 不仅服务 Git，还服务代码执行（/execute 端点）——isomorphic-git 导致的内存泄漏或未捕获异常会**中断所有 Node.js 功能**
4. 这不是简单的"加一个端点"，而是向已稳定运行的 Node.js 运行时引入一个持续的、不可回滚的依赖

---

## 对比矩阵

| 维度 | 方案 A（自编译 libgit2） | 方案 B（isomorphic-git） |
|------|------------------------|------------------------|
| 改动量 | 小（删除~400行 + 新增~150行脚本） | 大（重写~1400行 + 修改 bootstrap.js + npm打包） |
| 根因修复 | ✅ 直接修复 zlib 版本不匹配 | ⚠️ 绕过问题（换技术栈） |
| 风险等级 | 低 | 高（违反铁律7，Node稳定性风险） |
| 保留架构 | ✅ 完全保留 | ❌ 完全重写 |
| diff 支持 | ✅ 原生支持 | ❌ 需自定义实现 |
| 铁律影响 | 无（0/10违反） | 违反铁律#7（1/10违反） |
| CI 时间影响 | +10-15min（缓存后<1min） | +1-2min |
| App 体积 | 不变 | +1-2MB |
| 长期维护性 | 好（libgit2 C API成熟） | 中（依赖isomorphic-git+Node运行时） |
| 真机调试 | 好（C层错误直接） | 差（HTTP中间层+JS错误难调试） |
| 回退成本 | 低 | 高 |

---

## 明确推荐

**推荐方案 A — 自编译 libgit2 + USE_BUNDLED_ZLIB**

理由：
1. **精准修复根因**：USE_BUNDLED_ZLIB=ON 是 libgit2 官方标准方案，让 zlib 静态编译进 libgit2.a，彻底消除版本不匹配
2. **不违反任何铁律**：方案 B 违反铁律 #7，且 Node.js 崩溃不可恢复的风险不可接受
3. **改动量最小**：主要是删除第七轮临时 bypass 代码 + 一个编译脚本
4. **保留全部架构**：GitViewModel 不改，diff 继续工作，数据模型不变
5. **风险可控**：cmake 编译是标准流程，即使遇到问题也有明确调试方向
6. **CI 已有基础设施**：macos-14 runner 有 Xcode 15.4 + cmake，patch-xcframeworks.sh 能处理新 xcframework

### 实施建议

1. 创建 `scripts/build-libgit2.sh`（fork light-tech 脚本，精简单平台，加 USE_BUNDLED_ZLIB=ON）
2. CI 验证编译成功
3. 清理 GitService.swift 第七轮 bypass 代码
4. 清理 bridging header 和 project.yml
5. CI 全量构建 + 真机验证

可选优化：同时加 `-DREGEX_BACKEND=builtin` 跳过 libpcre 编译，进一步简化。

---

## 待明确事项

1. **真机错误信息**：第七轮 bypass 在真机的具体失败信息（非阻塞——方案 A 直接让 libgit2 用自带 zlib，不管系统 zlib 状态如何都能工作）
2. **CI 编译时间接受度**：首次 CI 增加~15分钟是否可接受（可缓存）
3. **是否需要模拟器支持**：当前方案只编译 iphoneos arm64，TrollStore 真机应用不需要模拟器

### 技术验证项（实施时确认）

- deps/zlib 目录存在性
- 编译后 libgit2.a 中包含 zlib 符号（`nm libgit2.a | grep deflateInit_`）
- 移除 libz.tbd 后链接成功
- REGEX_BACKEND=builtin 在 v1.3.1 中可用（如选择跳过 libpcre）
