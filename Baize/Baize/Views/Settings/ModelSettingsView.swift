import SwiftUI

/// Unified AI configuration view — provider selection + API key + model selection + verification
/// Merges APIKeySettingsView and ModelSettingsView into one page
struct UnifiedAIConfigView: View {
    @ObservedObject var appState: AppState

    @State private var selectedProvider: APIProvider = .openAI
    @State private var selectedModel: String = BaizeAPI.defaultModel
    @State private var apiKeyInput: String = ""
    @State private var isShowingKey = false
    @State private var keyStatus: KeyStatus = .unknown
    @State private var isVerifying = false
    @State private var connectionResult: Bool? = nil

    private let keychain = KeychainService()

    /// API Key 保存状态
    enum KeyStatus {
        case saved, unsaved, empty, unknown

        var label: String {
            switch self {
            case .saved: return "已保存"
            case .unsaved: return "未保存（修改未保存）"
            case .empty: return "未配置"
            case .unknown: return "未知"
            }
        }

        var color: Color {
            switch self {
            case .saved: return .green
            case .unsaved: return .orange
            case .empty: return .secondary
            case .unknown: return .secondary
            }
        }
    }

    /// 当前 Provider 的可用模型列表
    private var currentModels: [ModelInfo] {
        switch selectedProvider {
        case .openAI: return BaizeModels.OpenAI.allModels
        case .anthropic: return BaizeModels.Anthropic.allModels
        case .openRouter: return BaizeModels.OpenRouter.allModels
        }
    }

    /// 当前 Provider 的端点 URL
    private var currentEndpoint: String {
        switch selectedProvider {
        case .openAI: return BaizeAPI.openAIEndpoint
        case .anthropic: return BaizeAPI.anthropicEndpoint
        case .openRouter: return BaizeAPI.openRouterEndpoint
        }
    }

    var body: some View {
        Form {
            // Section 1: Provider selection
            Section(
                header: Text("选择 AI 服务"),
                footer: Text("OpenRouter 是一个聚合平台，可以用一个 Key 访问所有模型（包括 DeepSeek、GPT、Claude 等）。直接使用 OpenAI/Anthropic 需要各自的 Key。")
            ) {
                Picker("服务", selection: $selectedProvider) {
                    ForEach(APIProvider.allCases, id: \.self) { provider in
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            if isProviderKeyConfigured(provider) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedProvider) { newProvider in
                    // Load the API key for this provider from keychain
                    loadApiKeyForProvider(newProvider)
                    // Auto-select first model for this provider
                    let models = providerModels(newProvider)
                    if let first = models.first {
                        selectedModel = first.id
                    }
                    connectionResult = nil
                }
            }

            // Section 2: API Key for selected provider
            Section(
                header: Text("\(selectedProvider.displayName) API Key"),
                footer: Text("端点: \(currentEndpoint)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            ) {
                HStack(spacing: 12) {
                    if isShowingKey {
                        TextField("输入 API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        SecureField("输入 API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    Button(action: { isShowingKey.toggle() }) {
                        Image(systemName: isShowingKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Circle()
                        .fill(keyStatus.color)
                        .frame(width: 8, height: 8)
                    Text(keyStatus.label)
                        .foregroundColor(keyStatus.color)
                        .font(.subheadline)
                    Spacer()
                    Button("保存 Key") {
                        saveApiKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.isEmpty)
                }
            }

            // Section 3: Model selection
            Section(header: Text("选择模型")) {
                ForEach(currentModels) { model in
                    Button {
                        selectedModel = model.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedModel == model.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedModel == model.id ? .purple : .secondary)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("上下文: \(formatContext(model.contextWindow))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(model.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Section 4: Verify + Apply
            Section {
                HStack(spacing: 12) {
                    Button(action: verifyConnection) {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView().scaleEffect(0.7)
                            }
                            Text(isVerifying ? "验证中..." : "验证连接")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isVerifying || apiKeyInput.isEmpty)

                    if let result = connectionResult {
                        Label(
                            result ? "连接成功" : "连接失败",
                            systemImage: result ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundColor(result ? .green : .red)
                        .font(.subheadline)
                    }

                    Spacer()

                    Button("应用选择") {
                        applySelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModel.isEmpty)
                }
            }
        }
        .navigationTitle("AI 模型配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedProvider = appState.activeProvider
            selectedModel = appState.activeModel
            loadApiKeyForProvider(selectedProvider)
        }
        .onChange(of: apiKeyInput) { _ in
            if keyStatus == .saved && !apiKeyInput.isEmpty {
                keyStatus = .unsaved
            } else if apiKeyInput.isEmpty {
                keyStatus = .empty
            }
        }
    }

    // MARK: - Helpers

    /// 获取指定 Provider 的可用模型列表
    private func providerModels(_ provider: APIProvider) -> [ModelInfo] {
        switch provider {
        case .openAI: return BaizeModels.OpenAI.allModels
        case .anthropic: return BaizeModels.Anthropic.allModels
        case .openRouter: return BaizeModels.OpenRouter.allModels
        }
    }

    /// 检查指定 Provider 是否已配置 API Key
    private func isProviderKeyConfigured(_ provider: APIProvider) -> Bool {
        switch provider {
        case .openAI: return keychain.loadOpenAIKey() != nil
        case .anthropic: return keychain.loadAnthropicKey() != nil
        case .openRouter: return keychain.loadOpenRouterKey() != nil
        }
    }

    /// 从 Keychain 加载指定 Provider 的 API Key
    private func loadApiKeyForProvider(_ provider: APIProvider) {
        let key: String?
        switch provider {
        case .openAI: key = keychain.loadOpenAIKey()
        case .anthropic: key = keychain.loadAnthropicKey()
        case .openRouter: key = keychain.loadOpenRouterKey()
        }
        if let k = key, !k.isEmpty {
            apiKeyInput = k
            keyStatus = .saved
        } else {
            apiKeyInput = ""
            keyStatus = .empty
        }
    }

    /// 保存当前 Provider 的 API Key 到 Keychain
    private func saveApiKey() {
        do {
            switch selectedProvider {
            case .openAI: try keychain.saveOpenAIKey(apiKeyInput)
            case .anthropic: try keychain.saveAnthropicKey(apiKeyInput)
            case .openRouter: try keychain.saveOpenRouterKey(apiKeyInput)
            }
            keyStatus = .saved
        } catch {
            baizeLogger.error("Failed to save API key: \(error.localizedDescription)")
        }
    }

    /// 验证当前 Provider 连接
    private func verifyConnection() {
        guard !apiKeyInput.isEmpty else { return }
        // Save key first if not saved
        if keyStatus != .saved {
            saveApiKey()
        }
        isVerifying = true
        connectionResult = nil
        Task {
            let success: Bool
            switch selectedProvider {
            case .openAI:
                success = await OpenAIProvider(keychainService: keychain).verifyConnection()
            case .anthropic:
                success = await AnthropicProvider(keychainService: keychain).verifyConnection()
            case .openRouter:
                success = await OpenRouterProvider(keychainService: keychain).verifyConnection()
            }
            await MainActor.run {
                connectionResult = success
                isVerifying = false
            }
        }
    }

    /// 应用选中的 Provider 和模型到 appState
    private func applySelection() {
        // Ensure key is saved before applying
        if keyStatus == .unsaved && !apiKeyInput.isEmpty {
            saveApiKey()
        }
        appState.setActiveProvider(selectedProvider, model: selectedModel)
    }

    /// 格式化上下文窗口大小
    private func formatContext(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.0fM", Double(tokens) / 1_000_000.0) }
        if tokens >= 1000 { return String(format: "%.0fK", Double(tokens) / 1000.0) }
        return "\(tokens)"
    }
}
