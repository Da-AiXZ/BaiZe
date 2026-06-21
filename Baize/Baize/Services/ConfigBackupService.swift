import Foundation

/// 配置备份服务 — 将关键配置（Provider/Model/API Keys/Git 配置）备份到 App 容器外的 config.json
///
/// 解决 TrollStore 重装白泽后设置丢失的问题：
/// - 白泽定义了 `BaizePath.globalConfig`（`/var/mobile/Documents/Baize/.baize/config.json`）
///   该路径在 App 容器外，TrollStore 重装不会清除
/// - 本服务负责在配置变更时自动备份，App 启动时同步恢复
///
/// 线程安全：使用 actor 保护内部状态（节流任务、上次备份时间）
/// 启动恢复：`restoreSync()` 是 nonisolated static 方法，可在同步上下文（StateObject autoclosure）中调用
actor ConfigBackupService {

    // MARK: - Singleton

    /// 全局共享实例
    static let shared = ConfigBackupService()

    // MARK: - Properties

    /// 上次备份时间（actor 隔离，防止并发竞争）
    private var lastBackupTime: Date = .distantPast

    /// 待执行的节流备份任务 — scheduleBackup() 会取消旧任务并创建新任务
    private var pendingBackupTask: Task<Void, Never>?

    /// 节流间隔（秒）— 5 秒内多次配置变更只触发一次文件写入
    private static let throttleIntervalSeconds: TimeInterval = 5.0

    // MARK: - Initialization

    private init() {}

    // MARK: - Backup

    /// 执行完整备份 — 将当前配置序列化为 JSON 写入 config.json
    ///
    /// 在后台 Task 中调用，文件 IO 不阻塞主线程。
    /// 使用原子写入（`.atomic`），防止写入中途崩溃导致文件损坏。
    func backup() async {
        let config = gatherCurrentConfig()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            // 确保目录存在
            try? FileManager.default.createDirectory(
                atPath: BaizePath.internalData,
                withIntermediateDirectories: true
            )

            // 原子写入 — 先写入临时文件再替换，防止写入中途崩溃
            try data.write(
                to: URL(fileURLWithPath: BaizePath.globalConfig),
                options: [.atomic]
            )

            lastBackupTime = Date()
            baizeLogger.info("ConfigBackupService: backup completed — \(data.count) bytes → \(BaizePath.globalConfig)")
        } catch {
            baizeLogger.error("ConfigBackupService: backup failed — \(error.localizedDescription)")
        }
    }

    /// 节流自动备份 — 5 秒内多次调用只执行一次备份
    ///
    /// 在配置变更后调用（Provider 切换、API Key 保存等）。
    /// 取消任何待执行的备份任务，重新调度 5 秒后执行。
    func scheduleBackup() {
        pendingBackupTask?.cancel()
        pendingBackupTask = Task { [self] in
            // 等待节流间隔，期间如有新的 scheduleBackup() 调用则取消此任务
            try? await Task.sleep(nanoseconds: UInt64(Self.throttleIntervalSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.backup()
        }
    }

    /// 立即备份（跳过节流）— 用于手动触发
    func backupNow() async {
        pendingBackupTask?.cancel()
        pendingBackupTask = nil
        await backup()
    }

    // MARK: - Restore (Synchronous — for App Startup)

    /// 同步恢复配置 — 在 App 启动时调用
    ///
    /// **必须在 `AppState.restoreProviderSelection()` 之前执行**，
    /// 因为 restoreProviderSelection 从 UserDefaults 读取值，
    /// 而 TrollStore 重装后 UserDefaults 已被清空，需要先从 config.json 恢复。
    ///
    /// 此方法是 `nonisolated static`，因为：
    /// 1. 启动时不能 `await`（StateObject autoclosure 是同步闭包）
    /// 2. 纯文件读取 + UserDefaults/Keychain 写入，不需要 actor 状态
    /// 3. 容错设计：文件不存在或 JSON 解析失败 → 静默返回，不崩溃
    nonisolated static func restoreSync() {
        // 1. 检查备份文件是否存在
        guard FileManager.default.fileExists(atPath: BaizePath.globalConfig) else {
            baizeLogger.info("ConfigBackupService: no backup file found, skipping restore")
            return
        }

        // 2. 读取文件（容错）
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: BaizePath.globalConfig))
        } catch {
            baizeLogger.warning("ConfigBackupService: failed to read backup file — \(error.localizedDescription)")
            return
        }

        // 3. 解析 JSON（容错：解析失败不崩溃）
        let config: BackupConfig
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            config = try decoder.decode(BackupConfig.self, from: data)
        } catch {
            baizeLogger.warning("ConfigBackupService: failed to parse backup JSON — \(error.localizedDescription)")
            return
        }

        baizeLogger.info("ConfigBackupService: restoring from backup (version: \(config.version), lastBackup: \(config.lastBackupTime))")

        // 4. 恢复 UserDefaults 配置
        let ud = UserDefaults.standard

        // Provider / Model（与 AppState.persistProviderSelection 的 key 完全一致）
        if let provider = config.activeProvider {
            ud.set(provider, forKey: "com.baize.active-provider")
        }
        if let model = config.activeModel {
            ud.set(model, forKey: "com.baize.active-model")
        }

        // Custom Provider 配置
        if let endpoint = config.customEndpoint {
            ud.set(endpoint, forKey: BaizeAPI.customEndpointUDKey)
        }
        if let model = config.customModel {
            ud.set(model, forKey: BaizeAPI.customModelUDKey)
        }
        if let contextWindow = config.customContextWindow {
            ud.set(contextWindow, forKey: BaizeAPI.customContextWindowUDKey)
        }

        // Git 配置
        if let gitConfig = config.gitConfig {
            if let remoteURL = gitConfig.remoteURL {
                ud.set(remoteURL, forKey: BaizeGit.remoteURLUDKey)
            }
            if let username = gitConfig.username {
                ud.set(username, forKey: BaizeGit.usernameUDKey)
            }
        }

        // 5. 恢复 API Keys 到 Keychain
        // KeychainService.save() 会自动处理 Keychain + UserDefaults fallback 双写
        let keychain = KeychainService()

        if let openaiKey = config.apiKeys.openai {
            try? keychain.save(key: BaizeAPI.openAIKeyKeychainKey, value: openaiKey)
        }
        if let anthropicKey = config.apiKeys.anthropic {
            try? keychain.save(key: BaizeAPI.anthropicKeyKeychainKey, value: anthropicKey)
        }
        if let openrouterKey = config.apiKeys.openrouter {
            try? keychain.save(key: BaizeAPI.openRouterKeyKeychainKey, value: openrouterKey)
        }
        if let customKey = config.apiKeys.custom {
            try? keychain.save(key: BaizeAPI.customProviderKeyKeychainKey, value: customKey)
        }
        if let githubToken = config.apiKeys.githubToken {
            try? keychain.save(key: BaizeGit.tokenKeychainKey, value: githubToken)
        }

        baizeLogger.info("ConfigBackupService: restore completed successfully")
    }

    // MARK: - Read Backup Info (for UI)

    /// 获取上次备份时间（用于设置页 UI 显示）
    ///
    /// 直接从文件读取并解析，不依赖 actor 内部状态（因为 backup 可能由其他进程触发）。
    func getLastBackupTime() -> Date? {
        guard FileManager.default.fileExists(atPath: BaizePath.globalConfig) else {
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: BaizePath.globalConfig)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(BackupConfig.self, from: data) else {
            return nil
        }

        return config.lastBackupTime
    }

    // MARK: - Private Helpers

    /// 收集当前配置 — 从 UserDefaults + Keychain 读取所有需要备份的配置项
    ///
    /// 此方法在 actor 隔离上下文中执行，所有读取操作都是同步的。
    private func gatherCurrentConfig() -> BackupConfig {
        let ud = UserDefaults.standard
        let keychain = KeychainService()

        // Provider / Model
        let activeProvider = ud.string(forKey: "com.baize.active-provider")
        let activeModel = ud.string(forKey: "com.baize.active-model")

        // Custom Provider 配置
        let customEndpoint = ud.string(forKey: BaizeAPI.customEndpointUDKey)
        let customModel = ud.string(forKey: BaizeAPI.customModelUDKey)
        let customContextWindowRaw = ud.integer(forKey: BaizeAPI.customContextWindowUDKey)

        // API Keys（KeychainService.load 会自动处理 Keychain → UD fallback）
        let openaiKey = keychain.load(key: BaizeAPI.openAIKeyKeychainKey)
        let anthropicKey = keychain.load(key: BaizeAPI.anthropicKeyKeychainKey)
        let openrouterKey = keychain.load(key: BaizeAPI.openRouterKeyKeychainKey)
        let customKey = keychain.load(key: BaizeAPI.customProviderKeyKeychainKey)
        let githubToken = keychain.load(key: BaizeGit.tokenKeychainKey)

        // Git 配置
        let gitRemoteURL = ud.string(forKey: BaizeGit.remoteURLUDKey)
        let gitUsername = ud.string(forKey: BaizeGit.usernameUDKey)

        let apiKeys = BackupConfig.APIKeysBackup(
            openai: openaiKey,
            anthropic: anthropicKey,
            openrouter: openrouterKey,
            custom: customKey,
            githubToken: githubToken
        )

        // Git 配置仅在至少有一项非空时才备份
        let gitConfig: BackupConfig.GitConfigBackup?
        if gitRemoteURL == nil && gitUsername == nil {
            gitConfig = nil
        } else {
            gitConfig = BackupConfig.GitConfigBackup(
                remoteURL: gitRemoteURL,
                username: gitUsername
            )
        }

        return BackupConfig(
            version: "1.0",
            lastBackupTime: Date(),
            activeProvider: activeProvider,
            activeModel: activeModel,
            customEndpoint: customEndpoint,
            customModel: customModel,
            customContextWindow: customContextWindowRaw > 0 ? customContextWindowRaw : nil,
            apiKeys: apiKeys,
            gitConfig: gitConfig
        )
    }
}

// MARK: - Backup Data Model

/// 备份配置数据模型 — 序列化为 JSON 存储到 config.json
///
/// 所有字段均为 Optional（除 version 和 lastBackupTime），因为用户可能只配置了部分项。
/// 恢复时只写入非 nil 的字段，不会覆盖用户在重装后可能已手动设置的值。
struct BackupConfig: Codable {
    /// 备份格式版本（用于未来格式升级时的兼容性检测）
    var version: String = "1.0"

    /// 上次备份时间
    var lastBackupTime: Date

    /// 当前 Provider（APIProvider.rawValue，如 "openai" / "anthropic" / "openrouter" / "custom"）
    var activeProvider: String?

    /// 当前模型名（如 "gpt-4.1" / "claude-sonnet-4-20250514"）
    var activeModel: String?

    /// 自定义 Provider 端点 URL
    var customEndpoint: String?

    /// 自定义 Provider 模型名
    var customModel: String?

    /// 自定义 Provider contextWindow（token 数）
    var customContextWindow: Int?

    /// API Keys 备份（明文存储，TrollStore 环境可接受）
    var apiKeys: APIKeysBackup

    /// Git 配置备份（可选）
    var gitConfig: GitConfigBackup?

    // MARK: - Nested Types

    /// API Keys 备份结构
    struct APIKeysBackup: Codable {
        /// OpenAI API Key
        var openai: String?
        /// Anthropic API Key
        var anthropic: String?
        /// OpenRouter API Key
        var openrouter: String?
        /// 自定义 Provider API Key
        var custom: String?
        /// GitHub Token（用于 Git push 认证）
        var githubToken: String?
    }

    /// Git 配置备份结构
    struct GitConfigBackup: Codable {
        /// 远程仓库 URL
        var remoteURL: String?
        /// Git 用户名
        var username: String?
    }
}
