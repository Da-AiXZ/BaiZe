import Foundation

/// 搜索文件工具 — 使用 glob 模式搜索文件名
/// 只读工具，权限引擎自动 allow
struct SearchFilesTool: Tool {

    let name = "search_files"
    let description = "按文件名模式搜索文件。支持 glob 通配符（如 *.swift, src/**/*.ts）。返回匹配的文件路径列表。用于查找特定类型的文件、定位配置文件等。"
    let isReadOnly = true
    let isDestructive = false

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["pattern"],
        properties: [
            "pattern": SchemaBuilder.stringProperty(description: "文件名搜索模式（支持通配符，如 *.swift, test_*.py, config.*）"),
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
            let results = try fileSystemService.searchFiles(pattern: pattern, in: resolvedPath)

            if results.isEmpty {
                return ToolResult.success(
                    output: "未找到匹配 '\(pattern)' 的文件",
                    metadata: ["pattern": pattern, "count": "0"]
                )
            }

            // 格式化输出
            var outputLines: [String] = []
            outputLines.append("搜索模式: \(pattern)")
            outputLines.append("搜索目录: \(resolvedPath)")
            outputLines.append("")

            for filePath in results {
                outputLines.append("📄 \(filePath)")
            }

            outputLines.append("")
            outputLines.append("共找到 \(results.count) 个文件")

            toolLogger.info("search_files: pattern '\(pattern)' — \(results.count) results")
            return ToolResult.success(
                output: outputLines.joined(separator: "\n"),
                metadata: ["pattern": pattern, "count": "\(results.count)"]
            )
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}