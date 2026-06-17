import Foundation

/// 精确字符串替换编辑工具 — 类似 Claude Code 的 edit_file
/// 在文件中查找指定字符串并替换为新字符串
/// 破坏性工具，权限引擎需要 ask
/// 适用场景：修改代码片段、修复 bug、更新配置等
struct EditFileTool: Tool {

    let name = "edit_file"
    let description = "在文件中精确替换字符串。需要提供 old_string（要替换的原文）和 new_string（替换后的新文本）。old_string 必须与文件内容精确匹配。适用于修改代码片段、修复 bug 等。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["path", "old_string", "new_string"],
        properties: [
            "path": SchemaBuilder.pathProperty(description: "要编辑的文件路径"),
            "old_string": SchemaBuilder.stringProperty(description: "要替换的原始字符串（必须与文件内容精确匹配）"),
            "new_string": SchemaBuilder.stringProperty(description: "替换后的新字符串"),
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
        guard let oldString = input["old_string"] as? String else {
            return ToolResult.error(message: "缺少必填参数: old_string")
        }
        guard let newString = input["new_string"] as? String else {
            return ToolResult.error(message: "缺少必填参数: new_string")
        }

        let resolvedPath = context.resolvePath(path)

        do {
            let success = try fileSystemService.editFile(
                at: resolvedPath,
                oldString: oldString,
                newString: newString
            )

            if success {
                toolLogger.info("edit_file: \(resolvedPath.fileName) — replacement successful")
                return ToolResult.success(
                    output: "文件已修改: \(resolvedPath)",
                    metadata: ["path": resolvedPath]
                )
            } else {
                toolLogger.warning("edit_file: \(resolvedPath.fileName) — old_string not found")
                return ToolResult.error(
                    message: "未找到要替换的字符串。请确保 old_string 与文件内容精确匹配。"
                )
            }
        } catch {
            return ToolResult.error(message: error.localizedDescription)
        }
    }
}