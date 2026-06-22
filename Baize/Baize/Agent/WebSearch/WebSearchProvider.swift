import Foundation

/// 网络搜索引擎统一协议 — 各搜索引擎 Provider 实现此协议
///
/// T02 定义协议 + SearchResult struct（从 AppState.swift 移过来）
/// 各 Provider 实现在各自文件中：
/// - TavilySearchProvider（默认，AI 优化搜索）
/// - BingSearchProvider（微软搜索）
/// - GoogleSearchProvider（Google Custom Search）
/// - DuckDuckGoSearchProvider（免 API key，降级方案）
protocol WebSearchProvider: Sendable {
    /// 搜索引擎标识（如 "tavily", "bing", "google", "duckduckgo"）
    var id: String { get }

    /// 搜索引擎显示名称
    var displayName: String { get }

    /// 是否需要 API Key（DuckDuckGo 免 key）
    var requiresAPIKey: Bool { get }

    /// 执行搜索查询
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - maxResults: 最大结果数
    /// - Returns: 搜索结果列表
    /// - Throws: 网络错误、API 错误、JSON 解析错误
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

/// 搜索结果模型 — 统一的网络搜索结果数据结构
/// 注意：命名为 WebSearchResult 以避免与 FileSystemService.SearchResult（文件搜索结果）冲突
struct WebSearchResult: Sendable {
    /// 结果标题
    let title: String
    /// 结果 URL
    let url: String
    /// 结果摘要
    let snippet: String
    /// 来源搜索引擎标识
    let source: String

    init(title: String, url: String, snippet: String, source: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
    }
}

// MARK: - WebSearch Factory

/// 网络搜索 Provider 工厂 — 根据可用性选择最佳 Provider
///
/// 降级策略：
/// 1. 优先 Tavily（AI 优化搜索，需 API key）
/// 2. 其次 Bing（需 API key）
/// 3. 其次 Google（需 API key + CX ID）
/// 4. 最后 DuckDuckGo（免 key，始终可用）
enum WebSearchFactory {

    /// P1-#22 fix: 用户选择的搜索引擎的 UserDefaults 存储键
    static let selectedProviderUDKey = "com.baize.selected-search-engine"

    /// 创建最佳可用的搜索 Provider
    /// - Parameter keychainService: Keychain 服务（读取 API key）
    /// - Returns: 最佳可用的 Provider 实例
    /// P1-#22 fix: 优先使用用户保存的选择，其次自动推断
    static func createBestAvailable(keychainService: KeychainService) -> any WebSearchProvider {
        // P1-#22 fix: 优先从 UserDefaults 读取用户选择的搜索引擎
        if let savedProvider = UserDefaults.standard.string(forKey: selectedProviderUDKey) {
            return create(provider: savedProvider, keychainService: keychainService)
        }

        // 自动推断（无用户选择时）
        // 1. Tavily（需 API key）
        if let tavilyKey = loadTavilyKey(from: keychainService), !tavilyKey.isEmpty {
            return TavilySearchProvider(apiKey: tavilyKey)
        }

        // 2. Bing（需 API key）
        if let bingKey = loadBingKey(from: keychainService), !bingKey.isEmpty {
            return BingSearchProvider(apiKey: bingKey)
        }

        // 3. Google（需 API key + CX ID）
        if let googleKey = loadGoogleKey(from: keychainService), !googleKey.isEmpty {
            let cxId = UserDefaults.standard.string(forKey: "com.baize.google-cx-id") ?? ""
            if !cxId.isEmpty {
                return GoogleSearchProvider(apiKey: googleKey, cxId: cxId)
            }
        }

        // 4. DuckDuckGo（免 key，始终可用）
        webSearchLogger.info("WebSearch: no API key found, using DuckDuckGo (free)")
        return DuckDuckGoSearchProvider()
    }

    /// P1-#22 fix: 根据用户选择的 Provider 创建实例
    /// - Parameters:
    ///   - provider: Provider 标识（"tavily", "bing", "google", "duckduckgo"）
    ///   - keychainService: Keychain 服务
    /// - Returns: 对应的 Provider 实例（API key 缺失时降级到 DuckDuckGo）
    static func create(provider: String, keychainService: KeychainService) -> any WebSearchProvider {
        switch provider {
        case "tavily":
            if let key = loadTavilyKey(from: keychainService), !key.isEmpty {
                return TavilySearchProvider(apiKey: key)
            }
            // API key 缺失 — 降级到 DuckDuckGo
            webSearchLogger.warning("WebSearch: Tavily selected but no API key, falling back to DuckDuckGo")
            return DuckDuckGoSearchProvider()

        case "bing":
            if let key = loadBingKey(from: keychainService), !key.isEmpty {
                return BingSearchProvider(apiKey: key)
            }
            webSearchLogger.warning("WebSearch: Bing selected but no API key, falling back to DuckDuckGo")
            return DuckDuckGoSearchProvider()

        case "google":
            if let key = loadGoogleKey(from: keychainService), !key.isEmpty {
                let cxId = UserDefaults.standard.string(forKey: "com.baize.google-cx-id") ?? ""
                if !cxId.isEmpty {
                    return GoogleSearchProvider(apiKey: key, cxId: cxId)
                }
            }
            webSearchLogger.warning("WebSearch: Google selected but no API key/CX, falling back to DuckDuckGo")
            return DuckDuckGoSearchProvider()

        case "duckduckgo":
            return DuckDuckGoSearchProvider()

        default:
            return DuckDuckGoSearchProvider()
        }
    }

    // MARK: - API Key Loading

    /// Tavily API key 的 Keychain 存储键
    static let tavilyKeyKeychainKey = "com.baize.tavily-api-key"

    /// Bing API key 的 Keychain 存储键
    static let bingKeyKeychainKey = "com.baize.bing-api-key"

    /// Google API key 的 Keychain 存储键
    static let googleKeyKeychainKey = "com.baize.google-api-key"

    private static func loadTavilyKey(from keychain: KeychainService) -> String? {
        keychain.load(key: tavilyKeyKeychainKey)
    }

    private static func loadBingKey(from keychain: KeychainService) -> String? {
        keychain.load(key: bingKeyKeychainKey)
    }

    private static func loadGoogleKey(from keychain: KeychainService) -> String? {
        keychain.load(key: googleKeyKeychainKey)
    }
}
