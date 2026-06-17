import Foundation

/// 写入/创建文件工具 — 创建新文件或覆盖现有文件内容
/// 破坏性工具，权限引擎需要 ask（需用户确认）
struct WriteFileTool: Tool {

    let name = "write_file"
    let description = "创建新文件或覆盖现有文件内容。用于创建配置文件、生成代码、写入数据等。注意：此操作会覆盖已有文件。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["path", "content"],
        properties: [
            "path": SchemaBuilder.pathProperty(description: "文件路径（绝对路径或项目相对路径）。如果文件不存在将创建新文件。"),
            "content": SchemaBuilder.stringProperty(description: "要写入的完整文件内容"),
        ]
    )

    private let fileSystemService: FileSystemService

    init(fileSystemService: FileSystemService) {
        self.fileSystemService = fileSystemService
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let path = input["path"] as? String else {
            return ToolResult.error(message: "缺少必填参数: path")
        }
        guard let content = input["content"] as? String else {
            return ToolResult.error(message: "缺少必填参数: content")
        }

        let resolvedPath = context.resolvePath(path)

        do {
            try fileSystemService.writeFile(at: resolvedPath, content: content)
            toolLogger.info("write_file: \(resolvedPath.fileName) (\(content.utf8.count) bytes)")
            return ToolResult.success(
                output: "文件已写入: \(resolvedPath)",
                metadata: ["path": resolvedPath, "size": "\(content.utf8.count)"]
            )
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}