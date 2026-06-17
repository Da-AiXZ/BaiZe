import SwiftUI

/// 模型设置视图 — Provider 选择 + 模型选择 + Provider 详情卡片
/// Phase 2C: 支持多 Provider 切换和模型选择
struct ModelSettingsView: View {
    @ObservedObject var appState: AppState

    /// 当前选择的 Provider（本地状态，确认后同步到 appState）
    @State private var selectedProvider: APIProvider = .openAI

    /// 当前选择的模型 ID
    @State private var selectedModel: String = BaizeAPI.defaultModel

    /// 验证连接状态
    @State private var isVerifyingConnection: Bool = false
    @State private var connectionVerified: Bool? = nil

    /// 当前 Provider 的可用模型列表
    private var currentModels: [ModelInfo] {
        switch selectedProvider {
        case .openAI:
            return BaizeModels.OpenAI.allModels
        case .anthropic:
            return BaizeModels.Anthropic.allModels
        case .openRouter:
            return BaizeModels.OpenRouter.allModels
        }
    }

    /// 当前 Provider 的端点 URL
    private var currentEndpoint: String {
        switch selectedProvider {
        case .openAI:
            return BaizeAPI.openAIEndpoint
        case .anthropic:
            return BaizeAPI.anthropicEndpoint
        case .openRouter:
            return BaizeAPI.openRouterEndpoint
        }
    }

    /// 当前 Provider 是否已配置 API Key
    private var isCurrentProviderConfigured: Bool {
        guard let keychain = appState.keychainService else { return false }
        switch selectedProvider {
        case .openAI:
            return keychain.loadOpenAIKey() != nil
        case .anthropic:
            return keychain.loadAnthropicKey() != nil
        case .openRouter:
            return keychain.loadOpenRouterKey() != nil
        }
    }

    var body: some View {
        Form {
            // MARK: - Provider 选择
            Section(header: Text("Provider")) {
                Picker("选择 Provider", selection: $selectedProvider) {
                    ForEach(APIProvider.allCases, id: \.self) { provider in
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            if isProviderConfigured(provider) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedProvider) { newProvider in
                    // 切换 Provider 时，自动选择该 Provider 的第一个推荐模型
                    let models = providerModels(newProvider)
                    if let firstModel = models.first {
                        selectedModel = firstModel.id
                    }
                    connectionVerified = nil
                }
            }

            // MARK: - 模型选择
            Section(header: Text("模型")) {
                if currentModels.isEmpty {
                    Text("无可用模型")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(currentModels) { modelInfo in
                        ModelSelectionRow(
                            modelInfo: modelInfo,
                            isSelected: selectedModel == modelInfo.id,
                            onSelect: { selectedModel = modelInfo.id }
                        )
                    }
                }
            }

            // MARK: - Provider 详情卡片
            Section(header: Text("Provider 详情")) {
                // 端点
                VStack(alignment: .leading, spacing: 4) {
                    Text("端点")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currentEndpoint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }

                // API Key 状态
                HStack {
                    Text("API Key")
                    Spacer()
                    if isCurrentProviderConfigured {
                        Label("已配置", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    } else {
                        Label("未配置", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                    }
                }

                // 验证连接按钮
                HStack {
                    Button(action: verifyConnection) {
                        HStack(spacing: 6) {
                            if isVerifyingConnection {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(isVerifyingConnection ? "验证中..." : "验证连接")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isVerifyingConnection || !isCurrentProviderConfigured)

                    Spacer()

                    if let verified = connectionVerified {
                        Label(
                            verified ? "连接成功" : "连接失败",
                            systemImage: verified ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundColor(verified ? .green : .red)
                        .font(.subheadline)
                    }
                }
            }

            // MARK: - 应用选择
            Section {
                Button("应用选择") {
                    applySelection()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedModel.isEmpty)
            }
        }
        .navigationTitle("默认模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 初始化为当前 appState 中的选择
            selectedProvider = appState.activeProvider
            selectedModel = appState.activeModel
        }
    }

    // MARK: - Helper Methods

    /// 获取指定 Provider 的可用模型列表
    private func providerModels(_ provider: APIProvider) -> [ModelInfo] {
        switch provider {
        case .openAI:
            return BaizeModels.OpenAI.allModels
        case .anthropic:
            return BaizeModels.Anthropic.allModels
        case .openRouter:
            return BaizeModels.OpenRouter.allModels
        }
    }

    /// 检查指定 Provider 是否已配置 API Key
    private func isProviderConfigured(_ provider: APIProvider) -> Bool {
        guard let keychain = appState.keychainService else { return false }
        switch provider {
        case .openAI:
            return keychain.loadOpenAIKey() != nil
        case .anthropic:
            return keychain.loadAnthropicKey() != nil
        case .openRouter:
            return keychain.loadOpenRouterKey() != nil
        }
    }

    /// 验证当前 Provider 连接
    private func verifyConnection() {
        guard let keychain = appState.keychainService else { return }
        isVerifyingConnection = true
        connectionVerified = nil

        Task {
            let success: Bool
            switch selectedProvider {
            case .openAI:
                let provider = OpenAIProvider(keychainService: keychain)
                success = await provider.verifyConnection()
            case .anthropic:
                let provider = AnthropicProvider(keychainService: keychain)
                success = await provider.verifyConnection()
            case .openRouter:
                let provider = OpenRouterProvider(keychainService: keychain)
                success = await provider.verifyConnection()
            }

            await MainActor.run {
                connectionVerified = success
                isVerifyingConnection = false
            }
        }
    }

    /// 应用选中的 Provider 和模型
    private func applySelection() {
        appState.setActiveProvider(selectedProvider, model: selectedModel)
    }
}

// MARK: - Model Selection Row

/// 模型选择行 — 显示模型名称和上下文窗口
private struct ModelSelectionRow: View {
    let modelInfo: ModelInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // 选中指示器
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .purple : .secondary)
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelInfo.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("上下文: \(formatContextWindow(modelInfo.contextWindow)) tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(modelInfo.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 格式化上下文窗口大小
    private func formatContextWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.0fM", Double(tokens) / 1_000_000.0)
        } else if tokens >= 1000 {
            return String(format: "%.0fK", Double(tokens) / 1000.0)
        } else {
            return "\(tokens)"
        }
    }
}
