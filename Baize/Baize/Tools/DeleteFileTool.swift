import Foundation

/// 删除文件/目录工具 — 删除指定文件或空目录
/// 破坏性工具，权限引擎需要 ask（需用户确认）
/// FileSystemService.deleteItem 已内置安全检查：不允许删除项目根目录
struct DeleteFileTool: Tool {

    let name = "delete_file"
    let description = "删除文件或空目录。不可恢复，请谨慎使用。无法删除项目根目录、BAIZE.md 配置文件、/System /usr /bin 等系统路径。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["path"],
        properties: [
            "path": SchemaBuilder.pathProperty(description: "要删除的文件或空目录路径（绝对路径或项目相对路径）"),
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
            try fileSystemService.deleteItem(at: resolvedPath)
            toolLogger.info("delete_file: \(resolvedPath)")
            return ToolResult.success(
                output: "已删除: \(resolvedPath)",
                metadata: ["path": resolvedPath]
            )
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}
