import Foundation

/// DuckDuckGo 搜索 Provider — 免 API key 的降级搜索方案
///
/// 请求方式：GET https://html.duckduckgo.com/html/?q=xxx
/// 响应格式：HTML，需解析提取结果（简单正则匹配）
///
/// 注意：DuckDuckGo HTML 接口可能被限流或格式变化，
/// 作为降级方案使用，推荐配置 Tavily/Bing/Google API key 获得更稳定的结果
struct DuckDuckGoSearchProvider: WebSearchProvider {
    let id = "duckduckgo"
    let displayName = "DuckDuckGo"
    let requiresAPIKey = false

    init() {}

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. 构建请求 URL
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]

        guard let url = components.url else {
            throw WebSearchError.parseError("Invalid DuckDuckGo search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = BaizeAPI.requestTimeout

        // 2. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw WebSearchError.apiError(statusCode: httpResponse.statusCode, message: "DuckDuckGo error")
        }

        // 3. 解析 HTML
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.parseError("Cannot decode DuckDuckGo response as UTF-8")
        }

        // 4. 正则提取结果
        let results = parseHTML(html: html, maxResults: maxResults)
        return results
    }

    /// 解析 DuckDuckGo HTML 响应，提取搜索结果
    /// DuckDuckGo HTML 页面结构：
    /// <a class="result__a" href="...">Title</a>
    /// <a class="result__snippet" href="...">Snippet</a>
    private func parseHTML(html: String, maxResults: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // 提取结果块（每个结果以 class="result " 开始）
        // 使用简单正则提取标题、URL、摘要
        let titlePattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>([^<]*)</a>"#

        // 提取标题和 URL
        let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])

        let nsHTML = html as NSString
        let titleMatches = titleRegex?.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)) ?? []

        let snippetMatches = snippetRegex?.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)) ?? []

        for (index, match) in titleMatches.enumerated() {
            if index >= maxResults { break }

            // URL（第 1 捕获组）— DuckDuckGo 的 URL 可能是重定向链接
            let rawURL = match.numberOfRanges > 1 ? nsHTML.substring(with: match.range(at: 1)) : ""
            let url = decodeDuckDuckGoURL(rawURL)

            // 标题（第 2 捕获组）
            let title = match.numberOfRanges > 2 ? nsHTML.substring(with: match.range(at: 2)) : ""
            let cleanTitle = title.htmlDecoded()

            // 摘要（对应索引的 snippet）
            let snippet: String
            if index < snippetMatches.count {
                let snippetMatch = snippetMatches[index]
                let rawSnippet = snippetMatch.numberOfRanges > 1 ? nsHTML.substring(with: snippetMatch.range(at: 1)) : ""
                snippet = rawSnippet.htmlDecoded()
            } else {
                snippet = ""
            }

            if !url.isEmpty && !cleanTitle.isEmpty {
                results.append(WebSearchResult(
                    title: cleanTitle,
                    url: url,
                    snippet: snippet,
                    source: id
                ))
            }
        }

        return results
    }

    /// 解码 DuckDuckGo 重定向 URL
    /// DuckDuckGo 的 href 通常是 //duckduckgo.com/l/?uddg=<encoded_url>
    private func decodeDuckDuckGoURL(_ raw: String) -> String {
        // 提取 uddg 参数值
        if let uddgRange = raw.range(of: "uddg=") {
            let encoded = String(raw[uddgRange.upperBound...])
            // 去除可能的 & 后缀
            let cleanEncoded = encoded.split(separator: "&").first.map(String.init) ?? encoded
            // URL 解码
            return cleanEncoded.removingPercentEncoding ?? cleanEncoded
        }
        // 直接是 URL
        if raw.hasPrefix("//") {
            return "https:" + raw
        }
        return raw
    }
}

// MARK: - HTML Decoding Helper

private extension String {
    /// 简单 HTML 实体解码
    func htmlDecoded() -> String {
        var result = self
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        // 去除 HTML 标签
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
