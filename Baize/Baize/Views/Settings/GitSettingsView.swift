import SwiftUI

/// Git 凭据配置视图 — GitHub Token + remote URL + 用户名 + 测试连接
struct GitSettingsView: View {
    let appState: AppState

    @State private var token: String = ""
    @State private var remoteURL: String = ""
    @State private var username: String = ""

    /// 控制 Token 输入框显示/隐藏（修复 Bug 3: Token 内容不可见）
    @State private var showToken: Bool = false

    @State private var isTesting: Bool = false
    @State private var testResult: String?
    @State private var testSuccess: Bool = false

    @State private var isSaving: Bool = false
    @State private var saveSuccess: Bool = false

    var body: some View {
        Form {
            // 凭据配置 Section
            Section(header: Text("GitHub 凭据")) {
                // GitHub Token — 支持显示/隐藏切换（修复 Bug 3: Token 内容不可见）
                HStack {
                    Image(systemName: "key.fill")
                        .foregroundColor(Color.baizeAccent)
                        .frame(width: 24)
                    if showToken {
                        TextField("GitHub Personal Access Token", text: $token)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        SecureField("GitHub Personal Access Token", text: $token)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    Button(action: {
                        showToken.toggle()
                    }) {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                // 用户名
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundColor(Color.baizeAccent)
                        .frame(width: 24)
                    TextField("GitHub 用户名", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            // 远程仓库 Section
            Section(header: Text("远程仓库")) {
                HStack {
                    Image(systemName: "network")
                        .foregroundColor(Color.baizeAccent)
                        .frame(width: 24)
                    TextField("https://github.com/user/repo.git", text: $remoteURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
            }

            // 操作 Section
            Section {
                // 测试连接按钮
                Button(action: {
                    Task { await testConnection() }
                }) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text("测试连接")
                    }
                    .foregroundColor(Color.baizeAccent)
                }
                .disabled(isTesting || token.isEmpty)

                // 保存按钮
                Button(action: {
                    saveConfig()
                }) {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "tray.and.arrow.down.fill")
                        }
                        Text("保存配置")
                    }
                    .foregroundColor(Color.baizeSuccess)
                }
                .disabled(isSaving)

                // 删除 Token 按钮
                Button(role: .destructive, action: {
                    deleteConfig()
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("删除凭据")
                    }
                    .foregroundColor(Color.baizeError)
                }
            }

            // 测试结果 Section
            if let result = testResult {
                Section(header: Text("连接测试结果")) {
                    HStack(spacing: 8) {
                        Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(testSuccess ? Color.baizeSuccess : Color.baizeError)
                        Text(result)
                            .font(.system(size: 14))
                            .foregroundColor(testSuccess ? Color.baizeSuccess : Color.baizeError)
                    }
                }
            }

            // 保存成功提示
            if saveSuccess {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.baizeSuccess)
                        Text("配置已保存")
                            .font(.system(size: 14))
                            .foregroundColor(Color.baizeSuccess)
                    }
                }
            }

            // 帮助 Section
            Section(header: Text("使用说明")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 在 GitHub 创建 Personal Access Token (Settings → Developer settings → Personal access tokens)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("2. Token 需要至少 repo 权限（用于 push 代码）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("3. 用户名是你的 GitHub 用户名（不是邮箱）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("4. 远程 URL 格式: https://github.com/用户名/仓库名.git")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Git 配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadConfig()
        }
    }

    // MARK: - Actions

    /// 加载已保存的配置
    private func loadConfig() {
        let keychain = KeychainService()
        if let savedToken = keychain.loadGitToken() {
            token = savedToken
        }
        remoteURL = UserDefaults.standard.string(forKey: BaizeGit.remoteURLUDKey) ?? ""
        username = UserDefaults.standard.string(forKey: BaizeGit.usernameUDKey) ?? ""
    }

    /// 测试 GitHub Token 连接
    @MainActor
    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        guard let gitVM = appState.gitViewModel else {
            testResult = "Git 服务未初始化"
            testSuccess = false
            return
        }

        let success = await gitVM.testConnection(
            token: token,
            remoteURL: remoteURL,
            username: username
        )

        if success {
            testResult = "连接成功！Token 有效。"
            testSuccess = true
        } else {
            testResult = await appState.gitViewModel?.errorMessage ?? "连接失败，请检查 Token"
            testSuccess = false
        }
    }

    /// 保存配置
    @MainActor
    private func saveConfig() {
        isSaving = true
        defer { isSaving = false }

        let keychain = KeychainService()

        // 保存 Token（Keychain + UserDefaults fallback）
        if !token.isEmpty {
            do {
                try keychain.saveGitToken(token)
            } catch {
                baizeLogger.error("Failed to save Git token: \(error.localizedDescription)")
            }
        }

        // 保存远程 URL 和用户名（UserDefaults，非敏感信息）
        UserDefaults.standard.set(remoteURL, forKey: BaizeGit.remoteURLUDKey)
        UserDefaults.standard.set(username, forKey: BaizeGit.usernameUDKey)

        // 更新 ViewModel 状态
        appState.gitViewModel?.hasGitToken = !token.isEmpty

        saveSuccess = true
        // 3 秒后隐藏成功提示
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                saveSuccess = false
            }
        }
    }

    /// 删除凭据
    @MainActor
    private func deleteConfig() {
        let keychain = KeychainService()
        do {
            try keychain.deleteGitToken()
        } catch {
            baizeLogger.error("Failed to delete Git token: \(error.localizedDescription)")
        }
        UserDefaults.standard.removeObject(forKey: BaizeGit.remoteURLUDKey)
        UserDefaults.standard.removeObject(forKey: BaizeGit.usernameUDKey)

        token = ""
        remoteURL = ""
        username = ""
        testResult = nil
        saveSuccess = false

        appState.gitViewModel?.hasGitToken = false
    }
}
