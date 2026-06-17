import Foundation

/// 读取文件工具 — 读取指定文件的内容
/// 只读工具，权限引擎自动 allow
struct ReadFileTool: Tool {

    let name = "read_file"
    let description = "读取指定文件的完整内容。用于查看文件内容、分析代码、理解项目结构。"
    let isReadOnly = true
    let isDestructive = false

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["path"],
        properties: [
            "path": SchemaBuilder.pathProperty(description: "要读取的文件路径（绝对路径或项目相对路径）"),
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

        let resolvedPath = context.resolvePath(path)

        do {
            let content = try fileSystemService.readFile(at: resolvedPath)
            toolLogger.info("read_file: \(resolvedPath.fileName) (\(content.utf8.count) bytes)")
            return ToolResult.success(output: content, metadata: ["path": resolvedPath])
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}