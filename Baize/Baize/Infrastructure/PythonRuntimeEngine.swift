import Foundation

/// Python 运行时引擎 — 管理 CPython 单实例生命周期
///
/// App 启动时调一次 start()，在后台线程执行：
/// 1. setenv PYTHONHOME / PYTHONPATH / PYTHONDONTWRITEBYTECODE
/// 2. Py_Initialize()
/// 3. PyRun_SimpleString(bootstrap.py 代码)
///
/// bootstrap.py 启动 http.server 监听 127.0.0.1:48214，阻塞后台线程。
/// 后续所有 executeScript() 通过 HTTP POST 复用同一 Python 实例。
///
/// @warning Py_Initialize() 整个 App 生命周期只能调用一次，不支持重启。
///          若引擎崩溃则需重启 App。
final class PythonRuntimeEngine: @unchecked Sendable {

    // MARK: - Properties

    /// HTTP server 监听端口（48214，与 Node.js 的 48213 不冲突）
    private let port: Int

    /// 引擎是否已启动
    private var isStarted = false

    /// 启动锁 — 保护 isStarted 标志
    private let startLock = NSLock()

    /// HTTP 请求 session
    private let session: URLSession

    /// 缓存的 Python 版本字符串（如 "3.13.14"）
    private var cachedVersion: String?

    // MARK: - Initialization

    /// 创建 Python 运行时引擎
    /// - Parameter port: HTTP server 监听端口（默认 48214）
    init(port: Int = BaizePython.enginePort) {
        self.port = port
        let config = URLSessionConfiguration.default
        // URLSession 超时 = 脚本超时 + 5s 缓冲（双重超时保障）
        config.timeoutIntervalForRequest = BaizeRuntime.pythonTimeout + 5
        config.timeoutIntervalForResource = BaizeRuntime.pythonTimeout + 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - Engine Lifecycle

    /// 启动 Python 引擎（App 启动时调用一次）
    ///
    /// 流程：
    /// 1. 配置 PYTHONHOME / PYTHONPATH / PYTHONDONTWRITEBYTECODE
    /// 2. 在 2MB 栈后台线程调用 Py_Initialize()
    /// 3. 读取 bootstrap.py 内容，调用 PyRun_SimpleString() 执行
    /// 4. bootstrap.py 启动 http.server，阻塞后台线程
    func start() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !isStarted else {
            runtimeLogger.warning("PythonRuntimeEngine.start() called but engine already started — ignoring")
            return
        }

        // 1. 配置 Python 环境变量
        configurePythonHome()

        // 2. 读取 bootstrap.py
        guard let bootstrapPath = Bundle.main.path(
            forResource: BaizePython.bootstrapFileName,
            ofType: "py",
            inDirectory: BaizePython.bootstrapResourceDir
        ) else {
            runtimeLogger.error("bootstrap.py not found in App Bundle (directory: \(BaizePython.bootstrapResourceDir))")
            return
        }

        guard let bootstrapCode = try? String(contentsOfFile: bootstrapPath, encoding: .utf8) else {
            runtimeLogger.error("Failed to read bootstrap.py at \(bootstrapPath)")
            return
        }

        let enginePort = self.port

        // 3. 在 2MB 栈后台线程启动 Python
        let thread = Thread { [weak self] in
            runtimeLogger.info("Python engine thread starting...")

            // 初始化 Python 解释器
            Py_Initialize()
            runtimeLogger.info("Python interpreter initialized (Py_Initialize done)")

            // 执行 bootstrap.py — 启动 HTTP server（阻塞调用）
            // PyRun_SimpleString 返回 0 表示成功，-1 表示异常
            let result = PyRun_SimpleString(bootstrapCode)
            if result != 0 {
                runtimeLogger.error("bootstrap.py execution failed (PyRun_SimpleString returned \(result))")
            }

            runtimeLogger.error("Python engine thread exited (should not happen during app lifecycle)")

            // 引擎退出后标记为未启动
            self?.startLock.lock()
            self?.isStarted = false
            self?.startLock.unlock()
        }
        thread.stackSize = 2 * 1024 * 1024  // 2MB
        thread.qualityOfService = .userInitiated
        thread.start()

        isStarted = true
        runtimeLogger.info("Python engine start requested on port \(enginePort), bootstrap: \(bootstrapPath)")
    }

    /// 配置 PYTHONHOME / PYTHONPATH 环境变量
    private func configurePythonHome() {
        guard let resourcePath = Bundle.main.resourcePath else {
            runtimeLogger.error("Cannot get Bundle.main.resourcePath for PYTHONHOME")
            return
        }

        // PYTHONHOME = {resourcePath}/python
        // install_python 脚本将标准库复制到此目录
        let pythonHome = "\(resourcePath)/python"
        setenv("PYTHONHOME", pythonHome, 1)

        // PYTHONPATH = app 目录（bootstrap.py 所在目录，可为空）
        // 标准库路径由 PYTHONHOME 自动推导
        let appPath = "\(resourcePath)/python_scripts"
        setenv("PYTHONPATH", appPath, 1)

        // 禁止写 .pyc 文件（签名后的 bundle 不可修改）
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)

        runtimeLogger.info("PYTHONHOME=\(pythonHome), PYTHONPATH=\(appPath)")
    }

    // MARK: - Script Execution

    /// 通过 HTTP POST 执行 Python 脚本
    ///
    /// 流程：
    /// 1. 检查引擎是否已启动
    /// 2. 等待 HTTP server 就绪（健康检查轮询）
    /// 3. 发送 POST /execute 请求
    /// 4. 解析 JSON 响应
    ///
    /// - Parameters:
    ///   - script: Python 代码内容
    ///   - workingDir: 工作目录（可选，默认为项目根目录）
    ///   - timeout: 执行超时（秒）
    /// - Returns: ExecutionResult
    func executeScript(
        script: String,
        workingDir: String?,
        timeout: TimeInterval
    ) async -> RuntimeExecutor.ExecutionResult {

        guard isStarted else {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "Python 运行时未初始化。请重启 App。如问题持续，请检查 Python.framework 是否正确嵌入。",
                exitCode: -1,
                isError: true
            )
        }

        let ready = await waitForReady(maxWait: BaizePython.startupWaitTimeout)
        guard ready else {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "Python 引擎启动超时，HTTP server 未就绪（等待 \(Int(BaizePython.startupWaitTimeout))s）",
                exitCode: -1,
                isError: true
            )
        }

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

            let result = try JSONDecoder().decode(ExecuteResponse.self, from: data)
            return RuntimeExecutor.ExecutionResult(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: Int32(result.exitCode),
                isError: result.exitCode != 0
            )

        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                return RuntimeExecutor.ExecutionResult(
                    stdout: "",
                    stderr: "脚本执行超时（\(Int(timeout))秒）",
                    exitCode: -1,
                    isError: true
                )
            }
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "HTTP 请求错误: \(urlError.localizedDescription)",
                exitCode: -1,
                isError: true
            )
        } catch {
            return RuntimeExecutor.ExecutionResult(
                stdout: "",
                stderr: "执行失败: \(error.localizedDescription)",
                exitCode: -1,
                isError: true
            )
        }
    }

    /// 获取 Python 版本（通过 /health 端点）
    func getVersion() async -> String {
        if let cached = cachedVersion { return cached }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        do {
            let (data, _) = try await session.data(from: url)
            if let health = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                cachedVersion = health.pythonVersion
                return health.pythonVersion
            }
        } catch {
            // server 尚未就绪
        }
        return "Unknown"
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
                    runtimeLogger.info("Python engine ready after \(attempt) health check attempts")
                    return true
                }
            } catch {
                // server 尚未就绪
            }
            try? await Task.sleep(nanoseconds: BaizePython.healthCheckIntervalMs * 1_000_000)
        }

        runtimeLogger.error("Python engine not ready after \(Int(maxWait))s (\(attempt) attempts)")
        return false
    }
}

// MARK: - HealthResponse (Codable)

/// Python HTTP server /health 端点返回的健康状态
struct HealthResponse: Codable {
    /// 服务状态（"ok" 表示正常）
    let status: String
    /// Python 版本字符串（如 "3.13.14"）
    let pythonVersion: String
    /// 服务运行时间（秒）
    let uptime: Double
}
