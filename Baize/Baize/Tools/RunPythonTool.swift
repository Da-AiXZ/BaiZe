import Foundation

/// 运行 Python 脚本工具 — 通过 CPython 3.13+ iOS 嵌入模式执行 Python 脚本
/// 破坏性工具，权限引擎需要 ask
/// 执行流程：写入临时 .py 文件 → posix_spawn python3 → 收集输出 → 清理临时文件
struct RunPythonTool: Tool {

    let name = "run_python"
    let description = "运行 Python 脚本。将 Python 代码写入临时文件，通过 CPython 3.13+ iOS 嵌入模式执行，返回 stdout 和 stderr 输出。适用于数据分析、脚本自动化、机器学习推理等。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: [String: Any] = SchemaBuilder.objectSchema(
        required: ["script"],
        properties: [
            "script": SchemaBuilder.stringProperty(description: "要执行的 Python 代码内容"),
            "working_dir": SchemaBuilder.pathProperty(description: "脚本执行的工作目录（默认为项目根目录）"),
        ]
    )

    private let runtimeExecutor: RuntimeExecutor

    init(runtimeExecutor: RuntimeExecutor) {
        self.runtimeExecutor = runtimeExecutor
    }

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let script = input["script"] as? String else {
            return ToolResult.error(message: "缺少必填参数: script")
        }

        let workingDir = input["working_dir"] as? String ?? context.projectPath

        toolLogger.info("run_python: script (\(script.utf8.count) bytes) in \(workingDir)")

        let result = await runtimeExecutor.executePython(
            script: script,
            workingDir: workingDir
        )

        if result.isError {
            return ToolResult.error(
                message: "Python 执行失败 (exit code \(result.exitCode))\n\(result.formattedOutput)",
                metadata: ["exitCode": "\(result.exitCode)", "runtime": "python"]
            )
        } else {
            return ToolResult.success(
                output: result.formattedOutput,
                metadata: [
                    "exitCode": "\(result.exitCode)",
                    "runtime": "python",
                    "stdoutBytes": "\(result.stdout.utf8.count)",
                ]
            )
        }
    }
}