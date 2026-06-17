import Foundation
import KeychainAccess

/// Keychain 安全存储服务 — 使用 KeychainAccess 库封装
/// 用于存储 API Key（OpenAI/Anthropic/OpenRouter）等敏感信息
/// TrollStore 安装的 App 仍可正常使用 iOS Keychain
struct KeychainService {

    // MARK: - Properties

    /// KeychainAccess 实例（使用 Baize App 服务标识）
    private let keychain: Keychain

    // MARK: - Initialization

    init() {
        self.keychain = Keychain(service: "com.baize.app")
            .synchronizable(false)
            .accessibility(.whenUnlockedThisDeviceOnly)
    }

    // MARK: - Public API

    /// 安全存储值到 Keychain
    /// - Parameters:
    ///   - key: Keychain 键名
    ///   - value: 要存储的值
    func save(key: String, value: String) throws {
        do {
            try keychain.set(value, key: key)
            baizeLogger.info("Keychain: saved key '\(key)'")
        } catch {
            throw BaizeError.fileSystemError("Keychain 存储失败: \(key) — \(error.localizedDescription)")
        }
    }

    /// 从 Keychain 读取值
    /// - Parameter key: Keychain 键名
    /// - Returns: 存储的值，不存在时返回 nil
    func load(key: String) -> String? {
        do {
            let value = try keychain.get(key)
            if value != nil {
                baizeLogger.debug("Keychain: loaded key '\(key)'")
            }
            return value
        } catch {
            baizeLogger.error("Keychain: load failed for '\(key)' — \(error.localizedDescription)")
            return nil
        }
    }

    /// 从 Keychain 删除值
    /// - Parameter key: Keychain 键名
    func delete(key: String) throws {
        do {
            try keychain.remove(key)
            baizeLogger.info("Keychain: deleted key '\(key)'")
        } catch {
            throw BaizeError.fileSystemError("Keychain 删除失败: \(key) — \(error.localizedDescription)")
        }
    }

    /// 检查 Keychain 中是否存在某个键
    /// - Parameter key: Keychain 键名
    /// - Returns: 是否存在
    func contains(key: String) -> Bool {
        do {
            return try keychain.contains(key)
        } catch {
            return false
        }
    }

    // MARK: - API Key Convenience Methods

    /// 保存 OpenAI API Key
    func saveOpenAIKey(_ key: String) throws {
        try save(key: BaizeAPI.openAIKeyKeychainKey, value: key)
    }

    /// 读取 OpenAI API Key
    func loadOpenAIKey() -> String? {
        load(key: BaizeAPI.openAIKeyKeychainKey)
    }

    /// 保存 Anthropic API Key
    func saveAnthropicKey(_ key: String) throws {
        try save(key: BaizeAPI.anthropicKeyKeychainKey, value: key)
    }

    /// 读取 Anthropic API Key
    func loadAnthropicKey() -> String? {
        load(key: BaizeAPI.anthropicKeyKeychainKey)
    }

    /// 保存 OpenRouter API Key
    func saveOpenRouterKey(_ key: String) throws {
        try save(key: BaizeAPI.openRouterKeyKeychainKey, value: key)
    }

    /// 读取 OpenRouter API Key
    func loadOpenRouterKey() -> String? {
        load(key: BaizeAPI.openRouterKeyKeychainKey)
    }

    /// 检查是否至少配置了一个 API Key
    func hasAnyAPIKey() -> Bool {
        loadOpenAIKey() != nil || loadAnthropicKey() != nil || loadOpenRouterKey() != nil
    }
}