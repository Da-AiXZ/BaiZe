import Foundation

/// WebFetch 工具 — 抓取 URL 内容并可选 LLM 摘要
///
/// 流程：
/// 1. URLSession 抓取 URL 内容
/// 2. 简易 HTML→文本转换（去标签 + 保留文本结构）
/// 3. 如有 prompt 参数，调 APIGateway 对内容做 LLM 摘要
/// 4. 返回结果（原始文本或摘要）
struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "抓取指定 URL 的网页内容。可选提供 prompt 参数对内容进行 LLM 摘要。用于获取文档、API 参考等在线资源。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .web

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["url"],
        properties: [
            "url": ["type": "string", "description": "要抓取的 URL（http/https）"],
            "prompt": ["type": "string", "description": "可选 — 对抓取内容进行 LLM 摘要的提示词"]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let urlString = input["url"] as? String, !urlString.isEmpty else {
            return ToolResult.error(message: "缺少必填参数: url")
        }

        guard let url = URL(string: urlString) else {
            return ToolResult.error(message: "无效的 URL: \(urlString)")
        }

        // 1. 抓取 URL 内容
        var request = URLRequest(url: url)
        request.timeoutInterval = BaizeAPI.requestTimeout
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return ToolResult.error(message: "网络请求失败: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return ToolResult.error(message: "HTTP 错误: \(statusCode)")
        }

        // 2. 转换为文本
        guard let rawContent = String(data: data, encoding: .utf8) else {
            return ToolResult.error(message: "无法解码响应为 UTF-8 文本")
        }

        let textContent = htmlToText(rawContent)

        // 截断过长内容（避免超出 LLM 上下文）
        let maxChars = 8000
        let truncatedContent = textContent.count > maxChars
            ? String(textContent.prefix(maxChars)) + "\n...(内容已截断)"
            : textContent

        // 3. 如有 prompt，调 LLM 摘要
        if let prompt = input["prompt"] as? String, !prompt.isEmpty, let apiGateway = context.apiGateway {
            let summaryRequest: [Message] = [
                .system("你是一个内容摘要助手。根据用户的提示，从网页内容中提取相关信息。"),
                .user("提示: \(prompt)\n\n网页内容:\n\(truncatedContent)")
            ]

            do {
                var summary = ""
                let stream = await apiGateway.streamComplete(messages: summaryRequest, tools: [])
                for try await chunk in stream {
                    if case .textDelta(let text) = chunk {
                        summary += text
                    }
                }

                if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ToolResult.success(
                        output: "LLM 摘要返回空响应。原始内容:\n\(truncatedContent)",
                        metadata: ["url": urlString, "summarized": "false"]
                    )
                }

                return ToolResult.success(
                    output: summary,
                    metadata: ["url": urlString, "summarized": "true"]
                )
            } catch {
                // 摘要失败，降级返回原始内容
                return ToolResult.success(
                    output: "LLM 摘要失败: \(error.localizedDescription)\n\n原始内容:\n\(truncatedContent)",
                    metadata: ["url": urlString, "summarized": "false"]
                )
            }
        }

        // 4. 无 prompt，直接返回原始文本
        return ToolResult.success(
            output: truncatedContent,
            metadata: ["url": urlString, "summarized": "false"]
        )
    }

    // MARK: - HTML to Text

    /// 简易 HTML→文本转换 — 去除标签，保留文本结构
    private func htmlToText(_ html: String) -> String {
        var text = html

        // 移除 script/style 标签及内容
        text = text.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<nav[^>]*>[\\s\\S]*?</nav>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<footer[^>]*>[\\s\\S]*?</footer>",
            with: "",
            options: .regularExpression
        )

        // 将块级元素转换为换行
        let blockTags = ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr"]
        for tag in blockTags {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>",
                with: "\n",
                options: .regularExpression
            )
            text = text.replacingOccurrences(
                of: "</\(tag)>",
                with: "\n",
                options: .regularExpression
            )
        }

        // 移除所有 HTML 标签
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // HTML 实体解码
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")

        // 清理多余空行
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
