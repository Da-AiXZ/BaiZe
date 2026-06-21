import Foundation

// MARK: - MCP Tool Definition

/// MCP 工具定义 — 从 MCP server 的 tools/list 响应解析
struct MCPToolDef: Sendable, Codable {
    /// 工具名称
    let name: String
    /// 工具描述
    let description: String
    /// 输入参数 JSON Schema
    let inputSchema: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema.mapValues { AnyCodable($0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchema = try container.decodeIfPresent([String: AnyCodable].self, forKey: .inputSchema) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
    }
}

// MARK: - AnyCodable (for JSON Schema values)

/// 类型擦除的 Codable 包装器 — 用于存储 JSON Schema 中的任意类型值
struct AnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try container.encode(v.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

// MARK: - MCP Server Connection

/// MCP server 连接 — 持有 URLSession + config + 连接状态
/// 实现 JSON-RPC 2.0 over HTTP
class MCPServerConnection: @unchecked Sendable {

    /// 服务器配置
    let config: MCPServerConfig

    /// URLSession 实例
    private let session: URLSession

    /// 是否已连接
    private(set) var isConnected: Bool = false

    /// JSON-RPC 请求 ID 计数器
    private var requestId: Int = 0

    /// 同步锁（保护 requestId 自增）
    private let lock = NSLock()

    // MARK: - Initialization

    init(config: MCPServerConfig) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }

    // MARK: - JSON-RPC 2.0

    /// 发送 JSON-RPC 2.0 请求
    /// - Parameters:
    ///   - method: RPC 方法名（如 "tools/list", "tools/call"）
    ///   - params: 参数字典
    /// - Returns: 响应 JSON 的 result 字段
    func sendRequest(method: String, params: [String: Any] = [:]) async throws -> Any {
        guard let urlStr = config.url, let url = URL(string: urlStr) else {
            throw MCPError.invalidConfig("Missing or invalid URL for server \(config.name)")
        }

        // 构建 JSON-RPC 2.0 请求
        lock.lock()
        requestId += 1
        let currentId = requestId
        lock.unlock()

        var requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": currentId,
            "method": method
        ]
        if !params.isEmpty {
            requestBody["params"] = params
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // 发送请求
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse("Non-HTTP response from \(config.name)")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw MCPError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        // 解析 JSON-RPC 响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.parseError("Invalid JSON response from \(config.name)")
        }

        // 检查错误
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown"
            let code = error["code"] as? Int ?? -1
            throw MCPError.rpcError(code: code, message: message)
        }

        // 返回 result
        guard let result = json["result"] else {
            throw MCPError.parseError("Missing 'result' in JSON-RPC response from \(config.name)")
        }

        return result
    }

    // MARK: - MCP Protocol Methods

    /// 发送 initialize 请求 — 建立 MCP 连接
    func initialize() async throws {
        let result = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": [
                "name": "baize",
                "version": "1.0.0"
            ]
        ])
        _ = result  // 初始化响应包含 serverInfo 和 capabilities
        isConnected = true
        agentLogger.info("MCP: initialized server '\(config.name)'")
    }

    /// 发送 tools/list 请求 — 获取 MCP server 的工具列表
    /// - Returns: MCPToolDef 数组
    func toolsList() async throws -> [MCPToolDef] {
        let result = try await sendRequest(method: "tools/list")

        guard let resultDict = result as? [String: Any],
              let toolsArray = resultDict["tools"] as? [[String: Any]] else {
            return []
        }

        // 转换为 MCPToolDef
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let toolsData = try encoder.encode(AnyCodable(toolsArray))
        let anyTools = try decoder.decode([AnyCodable].self, from: toolsData)

        return anyTools.compactMap { anyTool in
            guard let dict = anyTool.value as? [String: Any] else { return nil }
            let name = dict["name"] as? String ?? ""
            let description = dict["description"] as? String ?? ""
            let inputSchema = (dict["inputSchema"] as? [String: Any]) ?? [:]
            return MCPToolDef(name: name, description: description, inputSchema: inputSchema)
        }
    }

    /// 发送 tools/call 请求 — 调用 MCP server 的工具
    /// - Parameters:
    ///   - name: 工具名称
    ///   - args: 工具参数
    /// - Returns: 调用结果文本
    func toolsCall(name: String, args: [String: Any]) async throws -> String {
        let params: [String: Any] = [
            "name": name,
            "arguments": args
        ]

        let result = try await sendRequest(method: "tools/call", params: params)

        // 解析结果 — MCP 返回 content 数组
        if let resultDict = result as? [String: Any],
           let content = resultDict["content"] as? [[String: Any]] {
            // 提取所有文本内容
            let texts = content.compactMap { item -> String? in
                guard let type = item["type"] as? String, type == "text" else { return nil }
                return item["text"] as? String
            }
            return texts.joined(separator: "\n")
        }

        // 降级：直接尝试字符串化
        if let text = result as? String {
            return text
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 断开连接
    func disconnect() {
        isConnected = false
        session.invalidateAndCancel()
        agentLogger.info("MCP: disconnected server '\(config.name)'")
    }
}

// MARK: - MCP Error

/// MCP 错误类型
enum MCPError: LocalizedError {
    case invalidConfig(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case parseError(String)
    case rpcError(code: Int, message: String)
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let msg): return "MCP 配置错误: \(msg)"
        case .invalidResponse(let msg): return "MCP 响应无效: \(msg)"
        case .httpError(let code, let body): return "MCP HTTP 错误 (\(code)): \(body.prefix(200))"
        case .parseError(let msg): return "MCP 解析错误: \(msg)"
        case .rpcError(let code, let msg): return "MCP RPC 错误 (\(code)): \(msg)"
        case .notConnected(let name): return "MCP server '\(name)' 未连接"
        }
    }
}
