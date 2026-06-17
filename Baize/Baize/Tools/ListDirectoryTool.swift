import Foundation

/// 列出目录内容工具 — 查看指定目录下的文件和文件夹
/// 只读工具，权限引擎自动 allow
struct ListDirectoryTool: Tool {

    let name = "list_directory"
    let description = "列出指定目录下的文件和文件夹。返回每个项目的名称、类型（文件/目录）、大小和修改时间。用于了解项目结构、查找文件等。"
    let isReadOnly = true
    let isDestructive = false

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: [],
        properties: [
            "path": SchemaBuilder.pathProperty(description: "要列出的目录路径（默认为项目根目录）"),
        ]
    )

    private let fileSystemService: FileSystemService

    init(fileSystemService: FileSystemService) {
        self.fileSystemService = fileSystemService
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        let path = input["path"] as? String
        let resolvedPath = context.resolvePath(path ?? context.projectPath)

        do {
            let items = try fileSystemService.listDirectory(at: resolvedPath)

            // 格式化输出为可读列表
            var outputLines: [String] = []
            outputLines.append("目录: \(resolvedPath)")
            outputLines.append("")

            for item in items {
                let typeIcon = item.isDirectory ? "📁" : "📄"
                let sizeInfo = item.isDirectory ? "" : " (\(item.size) bytes)"
                let modTime = item.modifiedAt.fileModifiedTime
                outputLines.append("\(typeIcon) \(item.name)\(sizeInfo) — \(modTime)")
            }

            outputLines.append("")
            outputLines.append("共 \(items.count) 个项目")

            toolLogger.info("list_directory: \(resolvedPath) — \(items.count) items")
            return ToolResult.success(
                output: outputLines.joined(separator: "\n"),
                metadata: ["path": resolvedPath, "count": "\(items.count)"]
            )
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}