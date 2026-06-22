import Foundation

// MARK: - Usage Record

/// 单次 API 调用用量记录
struct UsageRecord: Codable {
    /// 调用时间戳
    let timestamp: Date
    /// API 提供商（openai / anthropic / openrouter / deepseek / custom）
    let provider: String
    /// 模型 ID
    let model: String
    /// 输入 token 数
    let promptTokens: Int
    /// 输出 token 数
    let completionTokens: Int
    /// 估算费用（美元）
    let estimatedCost: Double
}

// MARK: - Usage Summary

/// 用量汇总（单日或自定义范围）
struct UsageSummary {
    /// 总 token 数（prompt + completion）
    let totalTokens: Int
    /// API 调用次数
    let apiCallCount: Int
    /// 总费用（美元）
    let totalCost: Double
}

// MARK: - Usage Tracker

/// 用量追踪器 — 按日持久化到 BaizePath.usageData/{yyyy-MM-dd}.json
/// actor 隔离保证并发安全，JSON 持久化模式与 ConversationStore 一致
actor UsageTracker {

    // MARK: - Properties

    /// 存储目录路径（BaizePath.usageData）
    private let storeDir: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    /// 日期格式化器（文件名用 yyyy-MM-dd）
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Initialization

    /// 初始化用量追踪器
    /// - Parameter storeDir: 存储目录路径，默认为 BaizePath.usageData
    init(storeDir: String = BaizePath.usageData) {
        self.storeDir = storeDir
    }

    // MARK: - Public API

    /// 追加用量记录到当日文件
    /// 逻辑：读取当日文件 → 追加 → 原子写入
    /// - Parameter record: 用量记录
    func record(_ record: UsageRecord) {
        do {
            try fileManager.createDirectory(atPath: storeDir, withIntermediateDirectories: true)

            let filePath = dayFilePath(for: record.timestamp)
            var records: [UsageRecord] = []

            // 读取当日已有记录
            if fileManager.fileExists(atPath: filePath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                records = (try? decoder.decode([UsageRecord].self, from: data)) ?? []
            }

            // 追加新记录
            records.append(record)

            // 原子写入（.iso8601 日期策略，与 ConversationStore 一致）
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)

            agentLogger.info("UsageTracker: recorded — \(record.provider)/\(record.model), prompt=\(record.promptTokens), completion=\(record.completionTokens)")
        } catch {
            agentLogger.error("UsageTracker: failed to record usage: \(error.localizedDescription)")
        }
    }

    /// 获取今日用量汇总
    /// - Returns: 今日的 token 总数、API 调用次数、总费用
    func getTodaySummary() -> UsageSummary {
        let records = loadDay(Date())
        let totalTokens = records.reduce(0) { $0 + $1.promptTokens + $1.completionTokens }
        let totalCost = records.reduce(0.0) { $0 + $1.estimatedCost }
        return UsageSummary(
            totalTokens: totalTokens,
            apiCallCount: records.count,
            totalCost: totalCost
        )
    }

    /// 加载指定日期的所有用量记录
    /// - Parameter date: 目标日期
    /// - Returns: 该日期的所有用量记录，文件不存在返回空数组
    func loadDay(_ date: Date) -> [UsageRecord] {
        let filePath = dayFilePath(for: date)
        guard fileManager.fileExists(atPath: filePath) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([UsageRecord].self, from: data)
        } catch {
            agentLogger.error("UsageTracker: failed to load day records: \(error.localizedDescription)")
            return []
        }
    }

    /// 删除超过 30 天的用量记录文件
    /// 遍历 storeDir，删除修改时间 > 30 天的 .json 文件
    func cleanupOldRecords() {
        guard let files = try? fileManager.contentsOfDirectory(atPath: storeDir) else {
            return
        }

        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 天前

        for fileName in files where fileName.hasSuffix(".json") {
            let filePath = (storeDir as NSString).appendingPathComponent(fileName)
            if let modDate = fileManager.fileModifiedDate(atPath: filePath),
               modDate < cutoffDate {
                try? fileManager.removeItem(atPath: filePath)
                agentLogger.info("UsageTracker: cleaned up old usage file: \(fileName)")
            }
        }
    }

    // MARK: - Private

    /// 获取指定日期的文件路径
    /// - Parameter date: 目标日期
    /// - Returns: {storeDir}/{yyyy-MM-dd}.json
    private func dayFilePath(for date: Date) -> String {
        let fileName = "\(dateFormatter.string(from: date)).json"
        return (storeDir as NSString).appendingPathComponent(fileName)
    }
}
