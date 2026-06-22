import SwiftUI

/// 搜索引擎设置 — 选择 Provider + 填写 API Key
@MainActor
struct SearchEngineSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var selectedProvider: String = "duckduckgo"
    @State private var tavilyKey: String = ""
    @State private var bingKey: String = ""
    @State private var googleKey: String = ""
    @State private var googleCXId: String = ""
    @State private var showSavedToast: Bool = false

    private let keychain = KeychainService()

    var body: some View {
        Form {
            Section("搜索引擎选择") {
                Picker("搜索引擎", selection: $selectedProvider) {
                    Text("Tavily（AI 优化）").tag("tavily")
                    Text("Bing").tag("bing")
                    Text("Google").tag("google")
                    Text("DuckDuckGo（免 Key）").tag("duckduckgo")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Tavily API Key") {
                SecureField("输入 Tavily API Key", text: $tavilyKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                Text("获取地址: https://tavily.com")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Bing API Key") {
                SecureField("输入 Bing API Key", text: $bingKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                Text("获取地址: https://www.microsoft.com/en-us/bing/apis/bing-web-search-api")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Google API Key") {
                SecureField("输入 Google API Key", text: $googleKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                TextField("Custom Search Engine ID (CX)", text: $googleCXId)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                Text("获取地址: https://console.cloud.google.com")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button(action: { saveSettings() }) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("保存设置")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("搜索引擎")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .overlay {
            if showSavedToast {
                Text("✅ 已保存")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.baizeSuccess)
                    .cornerRadius(10)
                    .transition(.opacity)
            }
        }
    }

    /// 加载已保存的设置
    /// P1-#22 fix: 从 UserDefaults 读取用户选择的搜索引擎（而非根据 API key 推断）
    private func loadSettings() {
        tavilyKey = keychain.load(key: WebSearchFactory.tavilyKeyKeychainKey) ?? ""
        bingKey = keychain.load(key: WebSearchFactory.bingKeyKeychainKey) ?? ""
        googleKey = keychain.load(key: WebSearchFactory.googleKeyKeychainKey) ?? ""
        googleCXId = UserDefaults.standard.string(forKey: "com.baize.google-cx-id") ?? ""

        // P1-#22 fix: 从 UserDefaults 读取用户选择的搜索引擎
        let savedProvider = UserDefaults.standard.string(forKey: WebSearchFactory.selectedProviderUDKey)
        if let provider = savedProvider {
            selectedProvider = provider
        } else {
            // 首次使用 — 根据 API key 推断默认 Provider
            if tavilyKey.isEmpty && bingKey.isEmpty && googleKey.isEmpty {
                selectedProvider = "duckduckgo"
            } else if !tavilyKey.isEmpty {
                selectedProvider = "tavily"
            } else if !bingKey.isEmpty {
                selectedProvider = "bing"
            } else if !googleKey.isEmpty {
                selectedProvider = "google"
            }
        }
    }

    /// 保存设置到 Keychain
    /// Bug #11 fix: key 为空时删除旧值，防止清空 key 后旧值仍留在 Keychain
    private func saveSettings() {
        // Tavily key
        if tavilyKey.isEmpty {
            try? keychain.delete(key: WebSearchFactory.tavilyKeyKeychainKey)
        } else {
            try? keychain.save(key: WebSearchFactory.tavilyKeyKeychainKey, value: tavilyKey)
        }
        // Bing key
        if bingKey.isEmpty {
            try? keychain.delete(key: WebSearchFactory.bingKeyKeychainKey)
        } else {
            try? keychain.save(key: WebSearchFactory.bingKeyKeychainKey, value: bingKey)
        }
        // Google key
        if googleKey.isEmpty {
            try? keychain.delete(key: WebSearchFactory.googleKeyKeychainKey)
        } else {
            try? keychain.save(key: WebSearchFactory.googleKeyKeychainKey, value: googleKey)
        }
        // Google CX ID
        if googleCXId.isEmpty {
            UserDefaults.standard.removeObject(forKey: "com.baize.google-cx-id")
        } else {
            UserDefaults.standard.set(googleCXId, forKey: "com.baize.google-cx-id")
        }

        // P1-#22 fix: 保存用户选择的搜索引擎到 UserDefaults
        UserDefaults.standard.set(selectedProvider, forKey: WebSearchFactory.selectedProviderUDKey)

        // 重新创建 WebSearchProvider — P1-#22 fix: 使用用户选择的 Provider 而非自动推断
        let webSearch = WebSearchFactory.create(provider: selectedProvider, keychainService: keychain)
        appState.webSearchProvider = webSearch

        withAnimation { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedToast = false }
        }
    }
}
