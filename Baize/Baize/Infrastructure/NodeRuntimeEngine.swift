import Foundation

/// Node.js 运行时引擎 — 管理 nodejs-mobile 单实例生命周期
///
/// App 启动时调一次 start()，在 2MB 栈后台线程启动 Node.js 引擎。
/// 后续所有 executeScript() 通过 HTTP POST 复用同一 Node 实例。
///
/// @warning node_start() 整个 App 生命周期只能调用一次，不支持重启。
///          若引擎崩溃则需重启 App。
final class NodeRuntimeEngine: @unchecked Sendable {

    // MARK: - Properties

    /// HTTP server 监听端口
    private let port: Int

    /// 引擎是否已启动（线程安全标志）
    private var isStarted = false

    /// 启动锁 — 保护 isStarted 标志
    private let startLock = NSLock()

    /// HTTP 请求 session（复用连接池）
    private let session: URLSession

    // MARK: - Initialization

    /// 创建 Node.js 运行时引擎
    /// - Parameter port: HTTP server 监听端口（默认 48213）
    init(port: Int = BaizeNode.enginePort) {
        self.port = port
        let config = URLSessionConfiguration.default
        // URLSession 超时 = 脚本超时 + 5s 缓冲（双重超时保障）
        config.timeoutIntervalForRequest = BaizeRuntime.nodeTimeout + 5
        config.timeoutIntervalForResource = BaizeRuntime.nodeTimeout + 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - Engine Lifecycle

    /// 启动 Node.js 引擎（App 启动时调用一次）
    ///
    /// 在 2MB 栈空间的后台线程调用 node_start()，不阻塞主线程。
    /// node_start() 阻塞后台线程直到 Node.js 退出（正常情况下 = App 生命周期）。
    func start() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !isStarted else {
            runtimeLogger.warning("NodeRuntimeEngine.start() called but engine already started — ignoring")
            return
        }

        // 从 App Bundle 获取 bootstrap.js 路径
        guard let bootstrapPath = Bundle.main.path(
            forResource: BaizeNode.bootstrapFileName,
            ofType: "js",
            inDirectory: BaizeNode.bootstrapResourceDir
        ) else {
            runtimeLogger.error("bootstrap.js not found in App Bundle resources (directory: \(BaizeNode.bootstrapResourceDir))")
            return
        }

        // 构建 node argv: ["node", "/path/to/bootstrap.js", "--port=48213"]
        let enginePort = self.port
        let arguments: [String] = [
            "node",
            bootstrapPath,
            "--port=\(enginePort)"
        ]

        // 在 2MB 栈空间的后台线程启动 Node.js
        // node_start 需要较大栈空间（V8 引擎初始化），默认 512KB 不够
        let thread = Thread { [weak self] in
            runtimeLogger.info("Node.js engine thread starting...")
            NodeEngineBridge.startEngine(withArguments: arguments)
            runtimeLogger.error("Node.js engine thread exited (should not happen during app lifecycle)")
            // 引擎退出后标记为未启动（虽然无法重启，但状态需正确）
            self?.startLock.lock()
            self?.isStarted = false
            self?.startLock.unlock()
        }
        thread.stackSize = 2 * 1024 * 1024  // 2MB — nodejs-mobile 官方推荐
        thread.qualityOfService = .userInitiated
        thread.start()

        isStarted = true
        runtimeLogger.info("Node.js engine start requested on port \(enginePort), bootstrap: \(bootstrapPath)")
    }

    // MARK: - Script Execution

    /// 通过 HTTP POST 执行 Node.js 脚本
    ///
    /// 流程：
    /// 1. 检查引擎是否已启动
    /// 2. 等待 HTTP server 就绪（健康检查轮询）
    /// 3. 发送 POST /execute 请求
    /// 4. 解析 JSON 响应
    ///
    /// - Parameters:
    ///   - script: JavaScript 代码内容
    ///   - workingDir: 工作目录（可选，默认为项目根目录）
    ///   - timeout: 执行超时（秒）
    /// - Returns: ExecutionResult
    func executeScript(
        script: String,
        workingDir: String?,
        timeout: TimeInterval
    ) async -> RuntimeExecutor.ExecutionResult {

        // 1. 确保引擎已启动
        guard isStarted else {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "Node.js 引擎未启动，请重启 App",
                exitCode: -1,
                isError: true
            )
        }

        // 2. 等待 HTTP server 就绪（健康检查）
        let ready = await waitForReady(maxWait: BaizeNode.startupWaitTimeout)
        guard ready else {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "Node.js 引擎启动超时，HTTP server 未就绪（等待 \(Int(BaizeNode.startupWaitTimeout))s）",
                exitCode: -1,
                isError: true
            )
        }

        // 3. 构建 HTTP 请求
        let requestBody: [String: Any] = [
            "script": script,
            "workingDir": workingDir ?? BaizePath.projectRoot,
            "timeout": timeout
        ]

        do {
            let url = URL(string: "http://127.0.0.1:\(port)/execute")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            // 4. 发送请求并等待响应
            let (data, response) = try await session.data(for: request)

            guard let httpResp = response as? HTTPURLResponse,
                  httpResp.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                return RuntimeExecutor.ExecutionResult(
                    stdout: "",
                    stderr: "HTTP 请求失败: 状态码 \(statusCode)",
                    exitCode: -1,
                    isError: true
                )
            }

            // 5. 解析 JSON 响应
            let result = try JSONDecoder().decode(ExecuteResponse.self, from: data)
            return RuntimeExecutor.ExecutionResult(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: Int32(result.exitCode),
                isError: result.exitCode != 0
            )

        } catch let urlError as URLError {
            // 超时处理
            if urlError.code == .timedOut {
                return RuntimeExecutor.ExecutionResult(
                    stdout: "",
                    stderr: "脚本执行超时（\(Int(timeout))秒）",
                    exitCode: -1,
                    isError: true
                )
            }
            // 其他 URL 错误（连接拒绝等）
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "HTTP 请求错误: \(urlError.localizedDescription)",
                exitCode: -1,
                isError: true
            )
        } catch {
            // JSON 解析错误等
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "执行失败: \(error.localizedDescription)",
                exitCode: -1,
                isError: true
            )
        }
    }

    // MARK: - Health Check

    /// 健康检查 — 轮询 GET /health 直到 server 就绪或超时
    ///
    /// - Parameter maxWait: 最大等待时间（秒）
    /// - Returns: true 如果 server 就绪，false 如果超时
    private func waitForReady(maxWait: TimeInterval) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date().addingTimeInterval(maxWait)
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            do {
                let (_, response) = try await session.data(from: url)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    runtimeLogger.info("Node.js engine ready after \(attempt) health check attempts")
                    return true
                }
            } catch {
                // server 尚未就绪（连接被拒绝），继续等待
            }
            // 轮询间隔 200ms
            try? await Task.sleep(nanoseconds: BaizeNode.healthCheckIntervalMs * 1_000_000)
        }

        runtimeLogger.error("Node.js engine not ready after \(Int(maxWait))s (\(attempt) attempts)")
        return false
    }
}

// MARK: - ExecuteResponse (Codable)

/// Node HTTP server 返回的执行结果
struct ExecuteResponse: Codable {
    /// 标准输出
    let stdout: String
    /// 标准错误输出
    let stderr: String
    /// 退出码（0 = 成功）
    let exitCode: Int
    /// 错误信息（可选）
    let error: String?
}
