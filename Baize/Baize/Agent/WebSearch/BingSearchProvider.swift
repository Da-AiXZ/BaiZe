import Foundation

/// Bing 搜索 Provider — 微软 Bing Search API
///
/// API 文档：https://www.microsoft.com/en-us/bing/apis/bing-web-search-api
/// 请求方式：GET，header: Ocp-Apim-Subscription-Key
/// 响应格式：JSON { webPages: { value: [{ name, url, snippet }] } }
struct BingSearchProvider: WebSearchProvider {
    let id = "bing"
    let displayName = "Bing"
    let requiresAPIKey = true

    /// Bing API Key（Ocp-Apim-Subscription-Key）
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. 构建请求 URL
        var components = URLComponents(string: BaizeAPI.bingEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(maxResults))
        ]

        guard let url = components.url else {
            throw WebSearchError.parseError("Invalid Bing search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webPages = json["webPages"] as? [String: Any],
              let values = webPages["value"] as? [[String: Any]] else {
            // 可能无结果
            return []
        }

        // 4. 转换为 SearchResult
        return values.compactMap { item in
            guard let name = item["name"] as? String,
                  let urlString = item["url"] as? String else {
                return nil
            }
            let snippet = item["snippet"] as? String ?? ""
            return WebSearchResult(
                title: name,
                url: urlString,
                snippet: snippet,
                source: id
            )
        }
    }
}
