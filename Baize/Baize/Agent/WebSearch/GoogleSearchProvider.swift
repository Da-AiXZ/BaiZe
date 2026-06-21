import Foundation

/// Google Custom Search Provider — Google Custom Search API
///
/// API 文档：https://developers.google.com/custom-search/v1/overview
/// 请求方式：GET，query params: q, key, cx
/// 响应格式：JSON { items: [{ title, link, snippet }] }
struct GoogleSearchProvider: WebSearchProvider {
    let id = "google"
    let displayName = "Google"
    let requiresAPIKey = true

    /// Google API Key
    private let apiKey: String

    /// Custom Search Engine ID (CX)
    private let cxId: String

    init(apiKey: String, cxId: String) {
        self.apiKey = apiKey
        self.cxId = cxId
    }

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. 构建请求 URL
        var components = URLComponents(string: BaizeAPI.googleEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: cxId),
            URLQueryItem(name: "num", value: String(min(maxResults, 10)))  // Google 最多 10 条
        ]

        guard let url = components.url else {
            throw WebSearchError.parseError("Invalid Google search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = BaizeAPI.requestTimeout

        // 2. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw WebSearchError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // 3. 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.parseError("Invalid Google response format")
        }

        // items 可能为 nil（无结果）
        guard let items = json["items"] as? [[String: Any]] else {
            return []
        }

        // 4. 转换为 SearchResult
        return items.compactMap { item in
            guard let title = item["title"] as? String,
                  let link = item["link"] as? String else {
                return nil
            }
            let snippet = item["snippet"] as? String ?? ""
            return WebSearchResult(
                title: title,
                url: link,
                snippet: snippet,
                source: id
            )
        }
    }
}
