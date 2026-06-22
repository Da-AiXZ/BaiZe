import Foundation

/// Tavily 搜索 Provider — AI 优化的搜索引擎（默认推荐）
///
/// API 文档：https://api.tavily.com/search
/// 请求方式：POST，body: { query, api_key, max_results }
/// 响应格式：JSON { results: [{ title, url, content }] }
struct TavilySearchProvider: WebSearchProvider {
    let id = "tavily"
    let displayName = "Tavily"
    let requiresAPIKey = true

    /// Tavily API Key
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. 构建请求
        let url = URL(string: BaizeAPI.tavilyEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = BaizeAPI.requestTimeout

        // 2. 构建请求体
        // P2 fix (round 2): 添加 search_depth=advanced 提高搜索质量
        // 添加 include_domains 排除低质量内容农场
        let requestBody: [String: Any] = [
            "query": query,
            "api_key": apiKey,
            "max_results": maxResults,
            "include_answer": false,
            "search_depth": "advanced"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // 3. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw WebSearchError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // 4. 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw WebSearchError.parseError("Invalid Tavily response format")
        }

        // 5. 转换为 SearchResult
        // P2 fix (round 2): 提高摘要长度限制 300→500，保留更多上下文
        var searchResults = results.compactMap { item -> WebSearchResult? in
            guard let title = item["title"] as? String,
                  let urlString = item["url"] as? String else {
                return nil
            }
            let content = item["content"] as? String ?? ""
            let snippet = content.count > 500 ? String(content.prefix(500)) + "..." : content
            let score = item["score"] as? Double ?? 0.0
            return WebSearchResult(
                title: title,
                url: urlString,
                snippet: snippet,
                source: id
            )
        }

        // P2 fix (round 2): 过滤低质量来源 — 移除已知的内容农场和低质量站点
        let lowQualityDomains: Set<String> = [
            "ezinearticles.com", "articlesbase.com", "hubpages.com",
            "squidoo.com", "buzzle.com", "selfgrowth.com"
        ]
        searchResults = searchResults.filter { result in
            guard let host = URL(string: result.url)?.host?.lowercased() else { return true }
            return !lowQualityDomains.contains { host.contains($0) }
        }

        return searchResults
    }
}

// MARK: - WebSearch Error

/// 网络搜索错误类型
enum WebSearchError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "搜索请求返回无效响应"
        case .apiError(let code, let msg): return "搜索 API 错误 (\(code)): \(msg.prefix(200))"
        case .parseError(let msg): return "搜索结果解析错误: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}
