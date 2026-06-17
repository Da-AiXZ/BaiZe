import Foundation

/// LLM Provider 统一协议
/// 所有 Provider 必须是 Sendable struct
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsFunctionCalling: Bool { get }
    var availableModels: [ModelInfo] { get }
    var isConfigured: Bool { get }

    func streamComplete(
        messages: [Message],
        tools: [APIGateway.ToolDefinition],
        model: String
    ) -> AsyncThrowingStream<APIGateway.LLMChunk, Error>

    func verifyConnection() async -> Bool
}

/// 模型信息
struct ModelInfo: Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let provider: String
    let contextWindow: Int
}

/// Provider 层错误
enum ProviderError: Error, LocalizedError {
    case notRegistered(String)
    case notConfigured(String)
    case apiError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRegistered(let id): return "Provider '\(id)' not registered"
        case .notConfigured(let id): return "Provider '\(id)' API Key not configured"
        case .apiError(let msg): return "API Error: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        }
    }
}
