import Foundation

// MARK: - Export Format

/// 对话导出格式
enum ExportFormat: String, CaseIterable {
    case markdown
    case plaintext
    case json

    /// 文件扩展名
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plaintext: return "txt"
        case .json: return "json"
        }
    }

    /// 显示名称
    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .plaintext: return "纯文本"
        case .json: return "JSON"
        }
    }
}

// MARK: - Export Content Mode

/// 导出内容模式
enum ExportContentMode {
    /// 精简：仅对话文本
    case minimal
    /// 完整：含工具调用结果
    case full
}

// MARK: - Conversation Exporter

/// 对话导出器 — 将会话导出为 Markdown / 纯文本 / JSON
/// struct（非 actor，无状态），所有方法为纯函数
struct ConversationExporter {

    /// 导出会话到文件
    /// - Parameters:
    ///   - session: 对话会话
    ///   - format: 导出格式
    ///   - projectPath: 当前项目路径（用于确定 exports/ 目录）
    ///   - contentMode: 精简/完整
    /// - Returns: 导出文件 URL
    /// - Throws: 文件写入失败时抛出 BaizeError.fileSystemError
    func export(
        session: ConversationSession,
        format: ExportFormat,
        projectPath: String,
        contentMode: ExportContentMode
    ) throws -> URL {
        let fileManager = FileManager.default

        // 导出目录：{projectPath}/exports/
        let exportsDir = (projectPath as NSString).appendingPathComponent(BaizePath.exportsDirName)
        try fileManager.ensureDirectoryExists(atPath: exportsDir)

        let sanitizedTitle = sanitizeFilename(session.title)
        let fileName = "\(sanitizedTitle).\(format.fileExtension)"
        let filePath = (exportsDir as NSString).appendingPathComponent(fileName)
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            switch format {
            case .markdown:
                let content = exportMarkdown(session, includeToolResults: contentMode == .full)
                try content.data(using: .utf8)?.write(to: fileURL, options: .atomic)

            case .plaintext:
                let content = exportPlaintext(session, includeToolResults: contentMode == .full)
                try content.data(using: .utf8)?.write(to: fileURL, options: .atomic)

            case .json:
                let data = try exportJSON(session)
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            throw BaizeError.fileSystemError("导出失败: \(error.localizedDescription)")
        }

        agentLogger.info("ConversationExporter: exported '\(session.title)' as \(format.displayName)")
        return fileURL
    }

    // MARK: - Private - Format Exporters

    /// 导出为 Markdown 格式
    /// - Parameters:
    ///   - session: 对话会话
    ///   - includeToolResults: 是否包含工具调用结果
    /// - Returns: Markdown 文本
    private func exportMarkdown(_ session: ConversationSession, includeToolResults: Bool) -> String {
        var lines: [String] = []

        lines.append("# \(session.title)")
        lines.append("")
        lines.append("**日期**: \(formatDate(session.createdAt))")
        lines.append("")
        lines.append("---")
        lines.append("")

        for message in session.messages {
            switch message {
            case .system:
                // 系统提示不导出（内部指令，非用户可见对话）
                continue

            case .user(let text):
                lines.append("## 👤 用户")
                lines.append(text)
                lines.append("")

            case .assistant(let text):
                lines.append("## 🤖 助手")
                lines.append(text)
                lines.append("")

            case .assistantWithToolCalls(let content, let toolCalls):
                lines.append("## 🤖 助手")
                if !content.isEmpty {
                    lines.append(content)
                    lines.append("")
                }
                if includeToolResults {
                    for call in toolCalls {
                        lines.append("### 🔧 工具调用: \(call.name)")
                        lines.append("```json")
                        lines.append(prettyPrintJSON(call.arguments))
                        lines.append("```")
                        lines.append("")
                    }
                }

            case .toolCall(_, let name, let arguments):
                if includeToolResults {
                    lines.append("### 🔧 工具调用: \(name)")
                    lines.append("```json")
                    lines.append(prettyPrintJSON(arguments))
                    lines.append("```")
                    lines.append("")
                }

            case .toolResult(_, let content):
                if includeToolResults {
                    lines.append("**结果**: \(content)")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 导出为纯文本格式
    /// - Parameters:
    ///   - session: 对话会话
    ///   - includeToolResults: 是否包含工具调用结果
    /// - Returns: 纯文本
    private func exportPlaintext(_ session: ConversationSession, includeToolResults: Bool) -> String {
        var lines: [String] = []

        lines.append("对话标题: \(session.title)")
        lines.append("日期: \(formatDate(session.createdAt))")
        lines.append("----------------------------------------")
        lines.append("")

        for message in session.messages {
            switch message {
            case .system:
                continue

            case .user(let text):
                lines.append("[用户]")
                lines.append(text)
                lines.append("")

            case .assistant(let text):
                lines.append("[助手]")
                lines.append(text)
                lines.append("")

            case .assistantWithToolCalls(let content, let toolCalls):
                lines.append("[助手]")
                if !content.isEmpty {
                    lines.append(content)
                    lines.append("")
                }
                if includeToolResults {
                    for call in toolCalls {
                        lines.append("[工具调用: \(call.name)]")
                        lines.append(call.arguments)
                        lines.append("")
                    }
                }

            case .toolCall(_, let name, let arguments):
                if includeToolResults {
                    lines.append("[工具调用: \(name)]")
                    lines.append(arguments)
                    lines.append("")
                }

            case .toolResult(_, let content):
                if includeToolResults {
                    lines.append("[工具结果]")
                    lines.append(content)
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 导出为 JSON 格式（直接序列化 ConversationSession）
    /// - Parameter session: 对话会话
    /// - Returns: JSON 数据
    private func exportJSON(_ session: ConversationSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(session)
    }

    // MARK: - Private - Helpers

    /// 替换文件名中的非法字符（/ \ : * ? " < > |）为下划线
    /// - Parameter name: 原始文件名
    /// - Returns: 安全的文件名
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name
            .components(separatedBy: invalidChars)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    /// 格式化日期为可读字符串
    /// - Parameter date: 日期
    /// - Returns: yyyy-MM-dd HH:mm:ss 格式字符串
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// 美化 JSON 字符串（如果输入是合法 JSON 则格式化，否则原样返回）
    /// - Parameter jsonString: JSON 字符串
    /// - Returns: 格式化后的 JSON 字符串
    private func prettyPrintJSON(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return jsonString
        }
        return prettyString
    }
}
