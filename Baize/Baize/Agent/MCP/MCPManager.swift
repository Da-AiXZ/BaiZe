import Foundation

/// MCP 连接管理器 — 管理远程/本地 MCP server 连接
///
/// T04 完整实现，替换 T01 在 AppState.swift 的占位空 actor
/// 管理 MCPServerConnection 实例，支持 connect/disconnect/listTools/callTool
/// 配置持久化到 UserDefaults（通过 MCPServerConfig.loadAll/saveAll）
actor MCPManager {

    // MARK: - Properties

    /// 已连接的 MCP server 字典 — serverId → MCPServerConnection
    private var connections: [String: MCPServerConnection] = [:]

    /// MCP server 配置列表（从 UserDefaults 加载）
    private var configs: [MCPServerConfig] = []

    // MARK: - Initialization

    init() {
        configs = MCPServerConfig.loadAll()
        agentLogger.info("MCPManager initialized with \(self.configs.count) server configs")
    }

    // MARK: - Connection Management

    /// 连接 MCP server
    /// - Parameter config: 服务器配置
    func connect(config: MCPServerConfig) async throws {
        guard config.transport == .remoteHTTP else {
            throw MCPError.invalidConfig("T04 仅支持 remoteHTTP 传输，\(config.transport.rawValue) 将在 T05 实现")
        }

        guard let _ = config.url else {
            throw MCPError.invalidConfig("Missing URL for remote HTTP server \(config.name)")
        }

        let connection = MCPServerConnection(config: config)
        try await connection.initialize()
        connections[config.id] = connection
        agentLogger.info("MCPManager: connected to server '\(config.name)' (id=\(config.id))")
    }

    /// 断开 MCP server 连接
    /// - Parameter serverId: 服务器 ID
    func disconnect(serverId: String) {
        if let connection = connections[serverId] {
            connection.disconnect()
            connections.removeValue(forKey: serverId)
            agentLogger.info("MCPManager: disconnected server (id=\(serverId))")
        }
    }

    /// 断开所有连接
    func disconnectAll() {
        for (_, connection) in connections {
            connection.disconnect()
        }
        connections.removeAll()
        agentLogger.info("MCPManager: disconnected all servers")
    }

    // MARK: - Tool Operations

    /// 列出指定 MCP server 的工具
    /// - Parameter serverId: 服务器 ID
    /// - Returns: MCPToolDef 数组
    func listTools(serverId: String) async throws -> [MCPToolDef] {
        guard let connection = connections[serverId] else {
            throw MCPError.notConnected(serverId)
        }
        return try await connection.toolsList()
    }

    /// 调用指定 MCP server 的工具
    /// - Parameters:
    ///   - serverId: 服务器 ID
    ///   - name: 工具名称
    ///   - args: 工具参数
    /// - Returns: 调用结果
    func callTool(serverId: String, name: String, args: [String: Any]) async throws -> String {
        guard let connection = connections[serverId] else {
            throw MCPError.notConnected(serverId)
        }
        return try await connection.toolsCall(name: name, args: args)
    }

    // MARK: - Server Config Management

    /// 获取所有配置（包括未连接的）
    /// - Returns: 配置数组
    func listServers() -> [MCPServerConfig] {
        configs
    }

    /// 添加服务器配置
    /// - Parameter config: 服务器配置
    func addServer(config: MCPServerConfig) {
        configs.append(config)
        MCPServerConfig.saveAll(configs)
        agentLogger.info("MCPManager: added server '\(config.name)' (id=\(config.id))")
    }

    /// 移除服务器配置（并断开连接）
    /// - Parameter serverId: 服务器 ID
    func removeServer(serverId: String) {
        disconnect(serverId: serverId)
        configs.removeAll { $0.id == serverId }
        MCPServerConfig.saveAll(configs)
        agentLogger.info("MCPManager: removed server (id=\(serverId))")
    }

    /// 更新服务器配置
    /// - Parameter config: 更新后的配置
    func updateServer(config: MCPServerConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
            MCPServerConfig.saveAll(configs)
            agentLogger.info("MCPManager: updated server '\(config.name)'")
        }
    }

    /// 检查服务器是否已连接
    /// - Parameter serverId: 服务器 ID
    /// - Returns: 是否已连接
    func isConnected(serverId: String) -> Bool {
        connections[serverId]?.isConnected ?? false
    }

    /// 获取已连接的服务器数量
    func connectedCount() -> Int {
        connections.values.filter { $0.isConnected }.count
    }
}
