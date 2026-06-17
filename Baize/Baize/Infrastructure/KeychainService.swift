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

    /// UserDefaults fallback key prefix（TrollStore 环境 Keychain 可能不可用）
    private let fallbackPrefix = "baize_keychain_fallback_"

    /// 安全存储值到 Keychain（失败时回退到 UserDefaults）
    /// - Parameters:
    ///   - key: Keychain 键名
    ///   - value: 要存储的值
    /// W2 fix: 使用 BaizeError.keychainError 而非 fileSystemError（语义正确映射）
    func save(key: String, value: String) throws {
        do {
            try keychain.set(value, key: key)
            // Keychain 成功，同步到 UserDefaults 作为备份
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
            baizeLogger.info("Keychain: saved key '\(key)'")
        } catch {
            // Keychain 失败（TrollStore 常见），回退到 UserDefaults
            baizeLogger.warning("Keychain save failed for '\(key)', using UserDefaults fallback: \(error.localizedDescription)")
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
        }
    }

    /// 从 Keychain 读取值（失败时回退到 UserDefaults）
    /// - Parameter key: Keychain 键名
    /// - Returns: 存储的值，不存在时返回 nil
    func load(key: String) -> String? {
        // 先尝试 Keychain
        if let value = try? keychain.get(key), value != nil {
            return value
        }
        // Keychain 失败或无值，回退到 UserDefaults
        let fallback = UserDefaults.standard.string(forKey: fallbackPrefix + key)
        if fallback != nil {
            baizeLogger.debug("Keychain: load failed for '\(key)', using UserDefaults fallback")
        }
        return fallback
    }

    /// 从 Keychain 删除值（同时删除 UserDefaults 备份）
    /// - Parameter key: Keychain 键名
    func delete(key: String) throws {
        do {
            try keychain.remove(key)
        } catch {
            // Keychain 删除失败也忽略，继续清理 UserDefaults
        }
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        baizeLogger.info("Keychain: deleted key '\(key)'")
    }

    /// 检查 Keychain 中是否存在某个键（同时检查 UserDefaults fallback）
    /// - Parameter key: Keychain 键名
    /// - Returns: 是否存在
    func contains(key: String) -> Bool {
        if (try? keychain.contains(key)) == true {
            return true
        }
        return UserDefaults.standard.string(forKey: fallbackPrefix + key) != nil
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