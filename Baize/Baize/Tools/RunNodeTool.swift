import Foundation

/// 运行 Node.js 脚本工具 — 通过 nodejs-mobile 进程内 Node.js 运行时执行 JS 脚本
/// 破坏性工具，权限引擎需要 ask
/// 执行流程：RuntimeExecutor → NodeMobileStrategy → NodeRuntimeEngine → HTTP POST /execute → vm.runInThisContext
struct RunNodeTool: Tool {

    let name = "run_node"
    let description = "运行 Node.js 脚本。通过 nodejs-mobile 进程内 Node.js 运行时（v18.20.4）执行 JavaScript 代码，支持 require/process/console 等 Node.js 全局 API，返回 stdout 和 stderr 输出。适用于运行构建工具、测试脚本、数据处理等。"
    let isReadOnly = false
    let isDestructive = true

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["script"],
        properties: [
            "script": SchemaBuilder.stringProperty(description: "要执行的 JavaScript 代码内容"),
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

        toolLogger.info("run_node: script (\(script.utf8.count) bytes) in \(workingDir)")

        let result = await runtimeExecutor.executeNode(
            script: script,
            workingDir: workingDir
        )

        if result.isError {
            return ToolResult.error(
                message: "Node.js 执行失败 (exit code \(result.exitCode))\n\(result.formattedOutput)",
                metadata: ["exitCode": "\(result.exitCode)", "runtime": "node"]
            )
        } else {
            return ToolResult.success(
                output: result.formattedOutput,
                metadata: [
                    "exitCode": "\(result.exitCode)",
                    "runtime": "node",
                    "stdoutBytes": "\(result.stdout.utf8.count)",
                ]
            )
        }
    }
}