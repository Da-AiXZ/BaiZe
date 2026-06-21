import Foundation

// MARK: - Model Pricing

/// 模型价格信息 — 每百万 token 美元
struct ModelPricing: Codable {
    /// 输入价格（每百万 token 美元）
    let inputPerMillion: Double
    /// 输出价格（每百万 token 美元）
    let outputPerMillion: Double
}

// MARK: - Baize Pricing

/// 模型价格表 — 硬编码主流模型价格 + 用户自定义覆盖
/// 价格来源：各厂商官方定价页（2025 年），OpenRouter 模型使用 provider/model 格式
enum BaizePricing {

    /// UserDefaults 存储前缀（用户自定义价格）
    private static let userPricingPrefix = "com.baize.pricing."

    /// 未知模型的默认兜底价格（不报错，使用保守默认值）
    private static let fallbackPricing = ModelPricing(inputPerMillion: 1.0, outputPerMillion: 2.0)

    /// 默认价格表 — 覆盖 Constants.swift 中 BaizeModels 定义的所有模型 ID
    /// 同时包含旧版模型 ID 以兼容历史会话
    static let defaultPricing: [String: ModelPricing] = [
        // MARK: OpenAI 原生模型
        "gpt-4.1": ModelPricing(inputPerMillion: 2.0, outputPerMillion: 8.0),
        "gpt-4.1-mini": ModelPricing(inputPerMillion: 0.4, outputPerMillion: 1.6),
        "gpt-4.1-nano": ModelPricing(inputPerMillion: 0.1, outputPerMillion: 0.4),
        "o3": ModelPricing(inputPerMillion: 10.0, outputPerMillion: 40.0),
        "o4-mini": ModelPricing(inputPerMillion: 1.1, outputPerMillion: 4.4),
        "gpt-4o": ModelPricing(inputPerMillion: 2.5, outputPerMillion: 10.0),
        "gpt-4o-mini": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.6),
        "gpt-4-turbo": ModelPricing(inputPerMillion: 10.0, outputPerMillion: 30.0),
        "gpt-4": ModelPricing(inputPerMillion: 30.0, outputPerMillion: 60.0),
        "gpt-3.5-turbo": ModelPricing(inputPerMillion: 0.5, outputPerMillion: 1.5),
        "o1": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 60.0),
        "o1-mini": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 12.0),
        "o1-preview": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 60.0),
        "o3-mini": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 12.0),

        // MARK: Anthropic 原生模型
        "claude-sonnet-4-20250514": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-opus-4-20250514": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "claude-haiku-4-20250414": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4.0),
        // 旧版 Anthropic 模型（兼容历史会话）
        "claude-3-5-sonnet-20241022": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-3-5-haiku-20241022": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4.0),
        "claude-3-opus-20240229": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "claude-3-sonnet-20240229": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-3-haiku-20240307": ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25),

        // MARK: OpenRouter 模型（provider/model 格式）
        "deepseek/deepseek-chat-v3.1": ModelPricing(inputPerMillion: 0.27, outputPerMillion: 1.10),
        "deepseek/deepseek-r1-0528": ModelPricing(inputPerMillion: 0.55, outputPerMillion: 2.19),
        "deepseek/deepseek-chat": ModelPricing(inputPerMillion: 0.27, outputPerMillion: 1.10),
        "deepseek/deepseek-r1": ModelPricing(inputPerMillion: 0.55, outputPerMillion: 2.19),
        "openai/gpt-4.1": ModelPricing(inputPerMillion: 2.0, outputPerMillion: 8.0),
        "openai/gpt-4o": ModelPricing(inputPerMillion: 2.5, outputPerMillion: 10.0),
        "openai/gpt-4o-mini": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.6),
        "openai/o4-mini": ModelPricing(inputPerMillion: 1.1, outputPerMillion: 4.4),
        "anthropic/claude-opus-4-20250514": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "anthropic/claude-sonnet-4-20250514": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "anthropic/claude-haiku-4-20250414": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4.0),
        "google/gemini-2.5-flash": ModelPricing(inputPerMillion: 0.3, outputPerMillion: 2.5),
        "google/gemini-2.5-pro": ModelPricing(inputPerMillion: 2.5, outputPerMillion: 15.0),
        "google/gemini-2.5-flash-lite": ModelPricing(inputPerMillion: 0.1, outputPerMillion: 0.4),
        "meta-llama/llama-4-maverick": ModelPricing(inputPerMillion: 0.2, outputPerMillion: 0.6),
        "meta-llama/llama-4-scout": ModelPricing(inputPerMillion: 0.1, outputPerMillion: 0.3),
        "mistralai/mistral-large-2411": ModelPricing(inputPerMillion: 2.0, outputPerMillion: 6.0),
        "mistralai/mistral-small-24b-instruct-2501": ModelPricing(inputPerMillion: 0.1, outputPerMillion: 0.3),
        "qwen/qwen3-32b-instruct": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.30),
        "qwen/qwen3-32b": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.30),
        "qwen/qwen3-235b-a22b": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.30),
    ]

    // MARK: - Cost Estimation

    /// 估算费用
    /// - Parameters:
    ///   - model: 模型 ID
    ///   - prompt: 输入 token 数
    ///   - completion: 输出 token 数
    /// - Returns: 估算费用（美元），未知模型使用兜底价格
    static func estimateCost(model: String, prompt: Int, completion: Int) -> Double {
        let pricing = getEffectivePricing(for: model)
        return Double(prompt) / 1_000_000.0 * pricing.inputPerMillion
             + Double(completion) / 1_000_000.0 * pricing.outputPerMillion
    }

    // MARK: - User Custom Pricing

    /// 设置用户自定义价格（持久化到 UserDefaults）
    /// - Parameters:
    ///   - pricing: 自定义价格
    ///   - model: 模型 ID
    static func setUserPricing(_ pricing: ModelPricing, for model: String) {
        let key = userPricingPrefix + model
        if let data = try? JSONEncoder().encode(pricing) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 获取用户自定义价格
    /// - Parameter model: 模型 ID
    /// - Returns: 用户自定义价格，未设置返回 nil
    static func getUserPricing(for model: String) -> ModelPricing? {
        let key = userPricingPrefix + model
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelPricing.self, from: data)
    }

    /// 获取生效价格（优先级：用户自定义 > 默认表 > 兜底）
    /// - Parameter model: 模型 ID
    /// - Returns: 生效的价格信息
    static func getEffectivePricing(for model: String) -> ModelPricing {
        if let userPricing = getUserPricing(for: model) {
            return userPricing
        }
        return defaultPricing[model] ?? fallbackPricing
    }
}
