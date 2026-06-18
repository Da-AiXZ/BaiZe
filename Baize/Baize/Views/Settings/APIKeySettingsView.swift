import SwiftUI

/// API Key 配置视图 — 安全存储 API Key 到 Keychain
/// 支持配置 OpenAI / Anthropic / OpenRouter API Key
/// 配置后自动验证连接状态（Phase 2C: 使用真实 Provider 验证）
struct APIKeySettingsView: View {
    @State private var openAIKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var isShowingOpenAIKey = false
    @State private var isShowingAnthropicKey = false
    @State private var isShowingOpenRouterKey = false
    @State private var openAIStatus: KeyStatus = .unknown
    @State private var anthropicStatus: KeyStatus = .unknown
    @State private var openRouterStatus: KeyStatus = .unknown
    @State private var isSaving = false

    // Phase 2C: 验证连接加载状态
    @State private var isVerifyingOpenAI = false
    @State private var isVerifyingAnthropic = false
    @State private var isVerifyingOpenRouter = false

    private let keychainService = KeychainService()

    enum KeyStatus {
        case unknown
        case configured    // Key 已存储
        case verified      // 连接验证成功
        case failed        // 连接验证失败
        case missing       // Key 未配置

        var icon: String {
            switch self {
            case .unknown: return "questionmark.circle"
            case .configured: return "key.fill"
            case .verified: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .missing: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .configured: return Color.baizeWarning
            case .verified: return Color.baizeSuccess
            case .failed: return Color.baizeError
            case .missing: return Color.baizeWarning
            }
        }

        var label: String {
            switch self {
            case .unknown: return "未知"
            case .configured: return "已配置"
            case .verified: return "已验证"
            case .failed: return "验证失败"
            case .missing: return "未配置"
            }
        }
    }

    var body: some View {
        Form {
            // OpenAI API Key
            APIKeySection(
                provider: "OpenAI",
                providerIcon: "openai",
                key: $openAIKey,
                isShowingKey: $isShowingOpenAIKey,
                status: openAIStatus,
                isVerifying: isVerifyingOpenAI,
                onSave: { saveOpenAIKey() },
                onDelete: { deleteOpenAIKey() },
                onVerify: { verifyOpenAIKey() }
            )

            // Anthropic API Key
            APIKeySection(
                provider: "Anthropic",
                providerIcon: "anthropic",
                key: $anthropicKey,
                isShowingKey: $isShowingAnthropicKey,
                status: anthropicStatus,
                isVerifying: isVerifyingAnthropic,
                onSave: { saveAnthropicKey() },
                onDelete: { deleteAnthropicKey() },
                onVerify: { verifyAnthropicKey() }
            )

            // OpenRouter API Key
            APIKeySection(
                provider: "OpenRouter",
                providerIcon: "openrouter",
                key: $openRouterKey,
                isShowingKey: $isShowingOpenRouterKey,
                status: openRouterStatus,
                isVerifying: isVerifyingOpenRouter,
                onSave: { saveOpenRouterKey() },
                onDelete: { deleteOpenRouterKey() },
                onVerify: { verifyOpenRouterKey() }
            )
        }
        .navigationTitle("API 配置")
        .onAppear { loadExistingKeys() }
    }

    // MARK: - Key Operations

    private func loadExistingKeys() {
        if let existing = keychainService.loadOpenAIKey() {
            openAIKey = existing
            openAIStatus = .configured
        } else {
            openAIStatus = .missing
        }

        if let existing = keychainService.loadAnthropicKey() {
            anthropicKey = existing
            anthropicStatus = .configured
        } else {
            anthropicStatus = .missing
        }

        if let existing = keychainService.loadOpenRouterKey() {
            openRouterKey = existing
            openRouterStatus = .configured
        } else {
            openRouterStatus = .missing
        }
    }

    private func saveOpenAIKey() {
        do {
            try keychainService.saveOpenAIKey(openAIKey)
            openAIStatus = .configured
        } catch {
            // Error handling
        }
    }

    private func deleteOpenAIKey() {
        do {
            try keychainService.delete(key: BaizeAPI.openAIKeyKeychainKey)
            openAIKey = ""
            openAIStatus = .missing
        } catch {
            // Error handling
        }
    }

    /// Phase 2C: 使用 OpenAIProvider 真实验证连接
    private func verifyOpenAIKey() {
        guard !openAIKey.isEmpty else { openAIStatus = .failed; return }
        isVerifyingOpenAI = true
        Task {
            // 保存 Key 后验证
            saveOpenAIKey()
            let provider = OpenAIProvider(keychainService: keychainService)
            let success = await provider.verifyConnection()
            await MainActor.run {
                openAIStatus = success ? .verified : .failed
                isVerifyingOpenAI = false
            }
        }
    }

    private func saveAnthropicKey() {
        do {
            try keychainService.saveAnthropicKey(anthropicKey)
            anthropicStatus = .configured
        } catch {
            // Error handling
        }
    }

    private func deleteAnthropicKey() {
        do {
            try keychainService.delete(key: BaizeAPI.anthropicKeyKeychainKey)
            anthropicKey = ""
            anthropicStatus = .missing
        } catch {
            // Error handling
        }
    }

    /// Phase 2C: 使用 AnthropicProvider 真实验证连接
    private func verifyAnthropicKey() {
        guard !anthropicKey.isEmpty else { anthropicStatus = .failed; return }
        isVerifyingAnthropic = true
        Task {
            saveAnthropicKey()
            let provider = AnthropicProvider(keychainService: keychainService)
            let success = await provider.verifyConnection()
            await MainActor.run {
                anthropicStatus = success ? .verified : .failed
                isVerifyingAnthropic = false
            }
        }
    }

    private func saveOpenRouterKey() {
        do {
            try keychainService.saveOpenRouterKey(openRouterKey)
            openRouterStatus = .configured
        } catch {
            // Error handling
        }
    }

    private func deleteOpenRouterKey() {
        do {
            try keychainService.delete(key: BaizeAPI.openRouterKeyKeychainKey)
            openRouterKey = ""
            openRouterStatus = .missing
        } catch {
            // Error handling
        }
    }

    /// Phase 2C: 使用 OpenRouterProvider 真实验证连接
    private func verifyOpenRouterKey() {
        guard !openRouterKey.isEmpty else { openRouterStatus = .failed; return }
        isVerifyingOpenRouter = true
        Task {
            saveOpenRouterKey()
            let provider = OpenRouterProvider(keychainService: keychainService)
            let success = await provider.verifyConnection()
            await MainActor.run {
                openRouterStatus = success ? .verified : .failed
                isVerifyingOpenRouter = false
            }
        }
    }
}

// MARK: - API Key Section

/// 单个 API Provider 配置 Section
private struct APIKeySection: View {
    let provider: String
    let providerIcon: String
    @Binding var key: String
    @Binding var isShowingKey: Bool
    let status: APIKeySettingsView.KeyStatus
    let isVerifying: Bool
    let onSave: () -> Void
    let onDelete: () -> Void
    let onVerify: () -> Void

    var body: some View {
        Section(header: Text(provider)) {
            // Key 输入
            HStack(spacing: 12) {
                if isShowingKey {
                    TextField("API Key", text: $key)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API Key", text: $key)
                        .textFieldStyle(.roundedBorder)
                }

                Button(action: { isShowingKey.toggle() }) {
                    Image(systemName: isShowingKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
            }

            // 状态显示
            HStack(spacing: 8) {
                Image(systemName: status.icon)
                    .foregroundColor(status.color)
                Text(status.label)
                    .foregroundColor(status.color)
                Spacer()
            }

            // 操作按钮
            HStack(spacing: 12) {
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty)

                // Phase 2C: 验证连接按钮增加 loading 指示
                Button(action: onVerify) {
                    HStack(spacing: 4) {
                        if isVerifying {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(isVerifying ? "验证中..." : "验证连接")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isVerifying)

                if status != .missing {
                    Button("删除", role: .destructive, action: onDelete)
                }
            }
        }
    }
}
