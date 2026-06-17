import Foundation

/// 搜索文件内容工具 — Grep 搜索文件内容中的关键词
/// 只读工具，权限引擎自动 allow
struct SearchContentTool: Tool {

    let name = "search_content"
    let description = "在文件内容中搜索指定关键词或模式。返回匹配的文件路径、行号和匹配内容。用于查找代码中的特定实现、搜索配置项等。"
    let isReadOnly = true
    let isDestructive = false

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["pattern"],
        properties: [
            "pattern": SchemaBuilder.stringProperty(description: "要搜索的关键词或字符串"),
            "path": SchemaBuilder.pathProperty(description: "搜索起始目录（默认为项目根目录）"),
        ]
    )

    private let fileSystemService: FileSystemService

    init(fileSystemService: FileSystemService) {
        self.fileSystemService = fileSystemService
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let pattern = input["pattern"] as? String else {
            return ToolResult.error(message: "缺少必填参数: pattern")
        }

        let searchPath = input["path"] as? String
        let resolvedPath = context.resolvePath(searchPath ?? context.projectPath)

        do {
            let results = try fileSystemService.searchContent(pattern: pattern, in: resolvedPath)

            if results.isEmpty {
                return ToolResult.success(
                    output: "未找到包含 '\(pattern)' 的内容",
                    metadata: ["pattern": pattern, "count": "0"]
                )
            }

            // 格式化输出
            var outputLines: [String] = []
            outputLines.append("搜索关键词: \(pattern)")
            outputLines.append("搜索目录: \(resolvedPath)")
            outputLines.append("")

            // 限制输出结果数量（避免过长）
            let maxResults = 50
            let displayedResults = results.prefix(maxResults)

            for result in displayedResults {
                outputLines.append("📄 \(result.filePath) [行 \(result.lineNumber)]")
                outputLines.append("   \(result.content)")
                outputLines.append("")
            }

            if results.count > maxResults {
                outputLines.append("... 共 \(results.count) 个结果，仅显示前 \(maxResults) 个")
            }

            toolLogger.info("search_content: pattern '\(pattern)' — \(results.count) results")
            return ToolResult.success(
                output: outputLines.joined(separator: "\n"),
                metadata: ["pattern": pattern, "count": "\(results.count)"]
            )
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}