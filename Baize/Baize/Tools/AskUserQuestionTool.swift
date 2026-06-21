import Foundation

/// AskUserQuestion 工具 — AI 结构化多问题提问
///
/// AI 使用此工具向用户提出结构化问题（带选项），等待用户回答后继续。
/// 不修改文件系统，仅发射 .askUserQuestion 事件，UI 弹出 AskUserQuestionView。
/// 用户回答后通过 AgentLoop 的 continuation 机制恢复执行。
struct AskUserQuestionTool: Tool {
    let name = "ask_user_question"
    let description = "向用户提出结构化问题以获取澄清或决策。支持多问题和选项。当需要用户在多个选项间选择时使用。"
    let isReadOnly = true
    let isDestructive = false
    let permissionLevel: ToolPermissionLevel = .autoAllow
    let category: ToolCategory = .planning

    let inputSchema: JSONSchemaDictionary = SchemaBuilder.objectSchema(
        required: ["questions"],
        properties: [
            "questions": [
                "type": "array",
                "description": "问题列表（最多 4 个）",
                "items": [
                    "type": "object",
                    "properties": [
                        "header": ["type": "string", "description": "问题标题（简短，最多 12 字符）"],
                        "question": ["type": "string", "description": "完整问题描述"],
                        "options": [
                            "type": "array",
                            "description": "可选选项列表（2-4 个），nil 表示自由文本回答",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": ["type": "string", "description": "选项标签"],
                                    "description": ["type": "string", "description": "选项说明"]
                                ],
                                "required": ["label", "description"]
                            ]
                        ]
                    ],
                    "required": ["header", "question"]
                ]
            ]
        ]
    )

    func execute(input: [String: Any], context: ToolExecutionContext) async -> ToolResult {
        guard let questionsArray = input["questions"] as? [[String: Any]] else {
            return ToolResult.error(message: "缺少必填参数: questions（应为数组）")
        }

        guard !questionsArray.isEmpty else {
            return ToolResult.error(message: "questions 数组不能为空")
        }

        guard questionsArray.count <= 4 else {
            return ToolResult.error(message: "最多 4 个问题，当前 \(questionsArray.count) 个")
        }

        var questions: [UserQuestion] = []
        for (index, qDict) in questionsArray.enumerated() {
            guard let header = qDict["header"] as? String else {
                return ToolResult.error(message: "第 \(index + 1) 个问题缺少 header 字段")
            }
            guard let question = qDict["question"] as? String else {
                return ToolResult.error(message: "第 \(index + 1) 个问题缺少 question 字段")
            }

            // 解析选项（可选）
            var options: [String]? = nil
            if let optionsArray = qDict["options"] as? [[String: Any]] {
                options = optionsArray.compactMap { $0["label"] as? String }
                if options?.isEmpty == true { options = nil }
            }

            questions.append(UserQuestion(header: header, question: question, options: options))
        }

        // 发射 .askUserQuestion 事件 — 通过 ToolResult.metadata 传递问题数据
        // AgentLoop 在收到 toolResult 后检查 toolName == "ask_user_question" 时发射事件并挂起
        let questionsJSON = questions.map { q in
            var dict: [String: Any] = [
                "header": q.header,
                "question": q.question
            ]
            if let opts = q.options {
                dict["options"] = opts
            }
            return dict
        }

        let questionsData = (try? JSONSerialization.data(withJSONObject: questionsJSON)) ?? Data()
        let questionsString = String(data: questionsData, encoding: .utf8) ?? "[]"

        return ToolResult.success(
            output: "已向用户提出 \(questions.count) 个问题，等待回答...",
            metadata: [
                "toolName": "ask_user_question",
                "questions": questionsString
            ]
        )
    }
}
