import Foundation

// MARK: - MCP Transport

/// MCP 传输方式 — 标识 MCP server 的连接方式
enum MCPTransport: String, Sendable, Codable {
    /// 远程 HTTP — JSON-RPC over HTTP POST
    case remoteHTTP
    /// 远程 SSE — Server-Sent Events（T04 暂不支持，预留）
    case remoteSSE
    /// 本地 stdio — 子进程 JSON-RPC over stdin/stdout（T05 实现）
    case localStdio
}

// MARK: - MCP Server Config

/// MCP server 配置模型 — 描述一个 MCP server 的连接信息
///
/// 持久化到 UserDefaults（非敏感配置）
/// 远程 HTTP server 需要 url 字段
/// 本地 stdio server 需要 command + args + env 字段（T05）
struct MCPServerConfig: Sendable, Codable, Identifiable {
    /// 唯一标识
    let id: String

    /// 显示名称
    var name: String

    /// 传输方式
    var transport: MCPTransport

    /// 远程 URL（remoteHTTP/remoteSSE 使用）
    var url: String?

    /// 本地命令（localStdio 使用，T05）
    var command: String?

    /// 命令参数（localStdio 使用）
    var args: [String]

    /// 环境变量（localStdio 使用）
    var env: [String: String]

    /// 是否启用
    var enabled: Bool

    // MARK: - Initialization

    init(
        id: String = UUID().uuidString,
        name: String,
        transport: MCPTransport = .remoteHTTP,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    // MARK: - UserDefaults Persistence

    /// UserDefaults 存储键
    static let storageKey = "com.baize.mcp-servers"

    /// 从 UserDefaults 加载所有 MCP server 配置
    /// - Returns: 配置数组（如果解码失败返回空数组）
    static func loadAll() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode([MCPServerConfig].self, from: data)) ?? []
    }

    /// 保存所有 MCP server 配置到 UserDefaults
    /// - Parameter configs: 配置数组
    static func saveAll(_ configs: [MCPServerConfig]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(configs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
