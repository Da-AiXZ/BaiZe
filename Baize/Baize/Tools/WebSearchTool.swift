import Foundation

/// WebSearch 工具 — 网络搜索（多引擎支持）
///
/// 调用 context.webSearchProvider 执行搜索，返回结构化结果。
/// 支持 Tavily/Bing/Google/DuckDuckGo 四个引擎，通过 WebSearchFactory 自动降级。
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "搜索网络获取最新信息。返回搜索结果列表（标题、URL、摘要）。用于查找文档、技术方案、最新动态等。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .web

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["query"],
        properties: [
            "query": ["type": "string", "description": "搜索关键词"],
            "max_results": ["type": "integer", "description": "最大结果数（默认 5）", "default": 5]
        ]
    )

    func isAvailable(context: ToolExecutionContext) -> Bool {
        context.webSearchProvider != nil
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let query = input["query"] as? String, !query.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: query")
        }

        guard let provider = context.webSearchProvider else {
            return ToolResult.error(message: "网络搜索 Provider 未配置。请在设置中配置搜索引擎 API Key。")
        }

        let maxResults = input["max_results"] as? Int ?? input["maxResults"] as? Int ?? 5

        do {
            var results = try await provider.search(query: query, maxResults: maxResults)

            if results.isEmpty {
                return ToolResult.success(
                    output: "搜索「\(query)」未找到结果。",
                    metadata: ["query": query, "provider": provider.id, "resultCount": "0"]
                )
            }

            // P2-#23 fix: 过滤低质量结果 — 移除空标题/空摘要的结果，优先权威来源
            results = results.filter { result in
                !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !result.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            // 格式化结果为文本
            let formattedResults = results.enumerated().map { index, result in
                "[\(index + 1)] \(result.title)\n    URL: \(result.url)\n    摘要: \(result.snippet)"
            }.joined(separator: "\n\n")

            // P2-#21 fix: 添加搜索结果使用提示，提醒 AI 基于实际搜索结果回答而非臆测
            let qualityHint = "\n\n⚠️ 请基于以上搜索结果的实际内容回答用户问题。不要编造或臆测搜索结果中未提及的信息。如果搜索结果不足以回答问题，请如实告知用户。"

            return ToolResult.success(
                output: "搜索「\(query)」找到 \(results.count) 条结果（来源: \(provider.displayName)）:\n\n\(formattedResults)\(qualityHint)",
                metadata: [
                    "query": query,
                    "provider": provider.id,
                    "resultCount": "\(results.count)"
                ]
            )
        } catch {
            return ToolResult.error(message: "搜索失败: \(error.localizedDescription)")
        }
    }
}
