import Foundation
import CryptoKit

// MARK: - Terminal History Record

/// 终端历史记录（按项目路径隔离持久化）
struct TerminalHistoryRecord: Codable {
    /// 项目绝对路径
    let projectPath: String
    /// 命令列表
    var commands: [String]
    /// 最后更新时间
    var lastUpdated: Date
}

// MARK: - Terminal History Store

/// 终端历史存储 — 按项目路径隔离持久化
/// 文件名：terminal_history_{projectHash}.json，projectHash 为 projectPath 的 SHA256 前 16 位
/// actor 隔离保证并发安全，JSON 持久化模式与 ConversationStore 一致
actor TerminalHistoryStore {

    // MARK: - Properties

    /// 存储目录路径（BaizePath.terminalHistory）
    private let storeDir: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    /// 最大历史记录条数
    private let maxCommands = 1000

    /// 不记入历史的命令（清屏命令）
    private let excludedCommands: Set<String> = ["clear", "cls"]

    // MARK: - Initialization

    /// 初始化终端历史存储
    /// - Parameter storeDir: 存储目录路径，默认为 BaizePath.terminalHistory
    init(storeDir: String = BaizePath.terminalHistory) {
        self.storeDir = storeDir
    }

    // MARK: - Public API

    /// 加载指定项目的命令历史
    /// - Parameter projectPath: 项目绝对路径
    /// - Returns: 命令列表，文件不存在返回空数组
    func load(projectPath: String) -> [String] {
        let filePath = historyFilePath(for: projectPath)
        guard fileManager.fileExists(atPath: filePath) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(TerminalHistoryRecord.self, from: data)
            return record.commands
        } catch {
            agentLogger.error("TerminalHistoryStore: failed to load history: \(error.localizedDescription)")
            return []
        }
    }

    /// 追加命令到项目历史（增量保存）
    /// 逻辑：读取 → 追加（去重连续相同命令）→ 上限 1000 条截断 → 原子写入
    /// clear/cls 命令不记入历史
    /// - Parameters:
    ///   - command: 执行的命令
    ///   - projectPath: 项目绝对路径
    func append(command: String, projectPath: String) {
        // 去除首尾空白
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }

        // 清屏命令不记入历史
        guard !excludedCommands.contains(trimmedCommand.lowercased()) else { return }

        do {
            try fileManager.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

            let filePath = historyFilePath(for: projectPath)
            var commands = load(projectPath: projectPath)

            // 去重连续相同命令
            if commands.last != trimmedCommand {
                commands.append(trimmedCommand)
            }

            // 上限截断：保留最近 maxCommands 条
            if commands.count > maxCommands {
                commands = Array(commands.suffix(maxCommands))
            }

            let record = TerminalHistoryRecord(
                projectPath: projectPath,
                commands: commands,
                lastUpdated: Date()
            )

            // 原子写入（.iso8601 日期策略，与 ConversationStore 一致）
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            agentLogger.error("TerminalHistoryStore: failed to append command: \(error.localizedDescription)")
        }
    }

    /// 清空指定项目的命令历史
    /// - Parameter projectPath: 项目绝对路径
    func clear(projectPath: String) {
        let filePath = historyFilePath(for: projectPath)
        if fileManager.fileExists(atPath: filePath) {
            try? fileManager.removeItem(atPath: filePath)
            agentLogger.info("TerminalHistoryStore: cleared history for project")
        }
    }

    // MARK: - Private

    /// 计算项目路径对应的历史文件路径
    /// projectHash = projectPath 的 SHA256 前 16 位（CryptoKit SHA256）
    /// - Parameter projectPath: 项目绝对路径
    /// - Returns: {storeDir}/terminal_history_{projectHash}.json
    private func historyFilePath(for projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        let projectHash = String(hashHex.prefix(16))
        let fileName = "terminal_history_\(projectHash).json"
        return (storeDir as NSString).appendingPathComponent(fileName)
    }
}
