import SwiftUI

/// T03: 新建项目向导 — NavigationStack 多页流程
///
/// 三页流程：
/// 1. 选择创建方式（空项目 / 从模板创建 / 从 Git clone 创建）
/// 2. 配置页（根据选择动态切换：项目名 / 模板选择 / Git URL）
/// 3. 创建中页（进度指示器 + 状态文本）
///
/// 创建逻辑：
/// - 空项目：创建目录 → 生成 BAIZE.md → git init → 注册 → 切换
/// - 模板项目：从 Bundle 复制模板 → 生成 BAIZE.md → git init → 注册 → 切换
/// - Git clone：调用 GitService.clone → 注册 → 切换
///
/// 项目名校验：非空 / 只允许 [a-zA-Z0-9_-] / 不与已有项目重名
/// 创建失败回滚：删除已创建的目录
struct NewProjectWizard: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Wizard State

    /// 创建方式枚举
    enum CreationMethod: String, CaseIterable, Identifiable {
        case empty = "空项目"
        case template = "从模板创建"
        case gitClone = "从 Git clone 创建"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .empty: return "folder.badge.plus"
            case .template: return "square.stack.3d.up"
            case .gitClone: return "arrow.down.circle"
            }
        }

        var description: String {
            switch self {
            case .empty: return "创建一个空的项目目录，包含基础 BAIZE.md 配置"
            case .template: return "从预置模板创建项目（React/Swift/Python/Node.js/HTML）"
            case .gitClone: return "从远程 Git 仓库克隆到本地"
            }
        }
    }

    /// 向导页面枚举
    enum WizardPage {
        case method       // 选择创建方式
        case configure    // 配置页
        case creating     // 创建中
    }

    @State private var currentPage: WizardPage = .method
    @State private var selectedMethod: CreationMethod?
    @State private var projectName: String = ""
    @State private var selectedTemplate: ProjectTemplate?
    @State private var gitURL: String = ""
    @State private var errorMessage: String?
    @State private var creationStatus: String = ""
    @State private var existingProjectNames: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                switch currentPage {
                case .method:
                    MethodSelectionPage(
                        selectedMethod: $selectedMethod,
                        onSelect: { method in
                            selectedMethod = method
                            // 根据选择设置默认值
                            switch method {
                            case .empty:
                                projectName = ""
                                selectedTemplate = nil
                            case .template:
                                selectedTemplate = ProjectTemplate.allCases.first
                                projectName = ""
                            case .gitClone:
                                gitURL = ""
                                projectName = ""
                            }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentPage = .configure
                            }
                        }
                    )

                case .configure:
                    ConfigurationPage(
                        method: selectedMethod ?? .empty,
                        projectName: $projectName,
                        selectedTemplate: $selectedTemplate,
                        gitURL: $gitURL,
                        errorMessage: $errorMessage,
                        existingNames: existingProjectNames,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentPage = .method
                            }
                        },
                        onCreate: {
                            Task { await performCreation() }
                        }
                    )

                case .creating:
                    CreatingPage(status: creationStatus)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                await loadExistingProjectNames()
            }
        }
    }

    /// 导航栏标题
    private var navTitle: String {
        switch currentPage {
        case .method: return "新建项目"
        case .configure: return selectedMethod?.rawValue ?? "配置"
        case .creating: return "创建中"
        }
    }

    // MARK: - Creation Logic

    /// 执行项目创建
    private func performCreation() async {
        guard let method = selectedMethod else {
            errorMessage = "请选择创建方式"
            return
        }

        // 校验项目名
        if let validationError = validateProjectName(projectName, existingNames: existingProjectNames) {
            errorMessage = validationError
            return
        }

        errorMessage = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage = .creating
        }

        let projectPath = (BaizePath.projectRoot as NSString).appendingPathComponent(projectName)

        do {
            switch method {
            case .empty:
                try await createEmptyProject(path: projectPath, name: projectName)
            case .template:
                guard let template = selectedTemplate else {
                    throw ProjectCreationError.templateNotSelected
                }
                try await createTemplateProject(path: projectPath, name: projectName, template: template)
            case .gitClone:
                try await createGitCloneProject(path: projectPath, name: projectName, url: gitURL)
            }

            // 注册到 ProjectRegistry
            await registerProject(name: projectName, path: projectPath, method: method)

            // 切换到新项目
            await appState.switchProject(to: projectPath)

            // 完成 — 关闭向导
            await MainActor.run {
                dismiss()
            }

        } catch {
            // 回滚：删除已创建的目录
            await rollback(path: projectPath)

            await MainActor.run {
                errorMessage = error.localizedDescription
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage = .configure
                }
            }
        }
    }

    /// 创建空项目
    /// 1. 创建目录  2. 生成 BAIZE.md  3. git init
    private func createEmptyProject(path: String, name: String) async throws {
        await updateStatus("正在创建项目目录...")
        let fm = FileManager.default
        try fm.ensureDirectoryExists(atPath: path)

        await updateStatus("正在生成 BAIZE.md...")
        try generateBaizeMD(at: path, name: name, stack: "Unknown")

        await updateStatus("正在初始化 Git 仓库...")
        try await initGitRepository(at: path)

        baizeLogger.info("NewProjectWizard: empty project '\(name)' created at \(path)")
    }

    /// 创建模板项目
    /// 1. 从 App Bundle 复制模板  2. 生成 BAIZE.md  3. git init
    private func createTemplateProject(path: String, name: String, template: ProjectTemplate) async throws {
        await updateStatus("正在创建项目目录...")
        let fm = FileManager.default
        try fm.ensureDirectoryExists(atPath: path)

        await updateStatus("正在复制模板文件...")
        // 从 App Bundle 复制模板
        if let bundlePath = Bundle.main.resourcePath?
            .appending("/\(template.bundleDirectoryName)") {
            if fm.fileExists(atPath: bundlePath) {
                // 复制模板目录内容到项目目录
                let contents = try fm.contentsOfDirectory(atPath: bundlePath)
                for item in contents {
                    let src = (bundlePath as NSString).appendingPathComponent(item)
                    let dst = (path as NSString).appendingPathComponent(item)
                    try fm.copyItem(atPath: src, toPath: dst)
                }
                baizeLogger.info("NewProjectWizard: template '\(template.displayName)' files copied")
            } else {
                // 模板目录不存在 — 降级为空项目
                baizeLogger.warning("NewProjectWizard: template bundle dir not found: \(bundlePath), creating empty project")
            }
        }

        await updateStatus("正在生成 BAIZE.md...")
        try generateBaizeMD(at: path, name: name, stack: template.stackDescription)

        await updateStatus("正在初始化 Git 仓库...")
        try await initGitRepository(at: path)

        baizeLogger.info("NewProjectWizard: template project '\(name)' (\(template.displayName)) created at \(path)")
    }

    /// 创建 Git clone 项目
    /// 1. 调用 GitService.clone  2. 注册
    private func createGitCloneProject(path: String, name: String, url: String) async throws {
        guard !url.isEmpty else {
            throw ProjectCreationError.invalidGitURL
        }

        await updateStatus("正在从 Git 克隆仓库...")
        guard let keychain = appState.keychainService else {
            throw ProjectCreationError.keychainUnavailable
        }

        // 创建 GitService 并 clone
        // 注意：clone 方法在 T02 实现，此处调用 stub（T02 完成后替换为真实实现）
        let gitService = GitService(repositoryPath: BaizePath.projectRoot, keychainService: keychain)

        do {
            try await gitService.clone(
                remoteURL: url,
                toPath: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        self.creationStatus = "\(status) (\(Int(progress * 100))%)"
                    }
                }
            )
            baizeLogger.info("NewProjectWizard: git clone '\(url)' → '\(path)' completed")
        } catch {
            // clone 失败 — 抛出错误以触发回滚
            throw ProjectCreationError.gitCloneFailed(error.localizedDescription)
        }

        // 生成 BAIZE.md
        await updateStatus("正在生成 BAIZE.md...")
        try generateBaizeMD(at: path, name: name, stack: "Git Clone")

        baizeLogger.info("NewProjectWizard: git clone project '\(name)' created at \(path)")
    }

    /// 生成 BAIZE.md 配置文件
    private func generateBaizeMD(at path: String, name: String, stack: String) throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateStr = dateFormatter.string(from: Date())

        let content = """
        ---
        name: \(name)
        stack: \(stack)
        created: \(dateStr)
        ---
        # \(name)

        ## 项目说明
        TODO: 添加项目说明
        """

        let baizeMDPath = (path as NSString).appendingPathComponent(BaizePath.projectConfigFile)
        try content.write(toFile: baizeMDPath, atomically: true, encoding: .utf8)
    }

    /// 初始化 Git 仓库
    private func initGitRepository(at path: String) async throws {
        guard let keychain = appState.keychainService else {
            throw ProjectCreationError.keychainUnavailable
        }
        let gitService = GitService(repositoryPath: path, keychainService: keychain)
        try await gitService.initRepository()
    }

    /// 注册项目到 ProjectRegistry
    private func registerProject(name: String, path: String, method: CreationMethod) async {
        guard let registry = appState.projectRegistry else { return }

        let stack: String
        let icon: String
        switch method {
        case .empty:
            stack = "Unknown"
            icon = "folder.fill"
        case .template:
            stack = selectedTemplate?.stackDescription ?? "Template"
            icon = selectedTemplate?.iconName ?? "square.stack.3d.up"
        case .gitClone:
            stack = "Git Clone"
            icon = "arrow.down.circle"
        }

        let entry = ProjectEntry(
            id: UUID(),
            name: name,
            path: path,
            stack: stack,
            icon: icon,
            lastOpened: Date()
        )
        await registry.add(entry)
        baizeLogger.info("NewProjectWizard: project '\(name)' registered in ProjectRegistry")
    }

    /// 回滚 — 删除已创建的目录
    private func rollback(path: String) async {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
            baizeLogger.warning("NewProjectWizard: rolled back — deleted \(path)")
        }
    }

    /// 更新创建状态文本
    @MainActor
    private func updateStatus(_ status: String) {
        creationStatus = status
    }

    /// 加载已有项目名列表（用于重名校验）
    private func loadExistingProjectNames() async {
        guard let registry = appState.projectRegistry else { return }
        let list = await registry.list()
        let names = Set(list.map { $0.name })
        await MainActor.run { self.existingProjectNames = names }
    }

    // MARK: - Validation

    /// 校验项目名
    /// - 非空
    /// - 只允许 [a-zA-Z0-9_-]
    /// - 不与已有项目重名
    private func validateProjectName(_ name: String, existingNames: Set<String>) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "项目名不能为空"
        }
        // 只允许字母、数字、下划线、连字符
        let allowedPattern = "^[a-zA-Z0-9_-]+$"
        let regex = try? NSRegularExpression(pattern: allowedPattern)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if regex?.firstMatch(in: trimmed, options: [], range: range) == nil {
            return "项目名只允许字母、数字、下划线和连字符"
        }
        if existingNames.contains(trimmed) {
            return "已存在同名项目，请更换名称"
        }
        return nil
    }
}

// MARK: - Project Creation Error

/// 项目创建错误枚举
enum ProjectCreationError: LocalizedError {
    case templateNotSelected
    case invalidGitURL
    case keychainUnavailable
    case gitCloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .templateNotSelected:
            return "请选择一个项目模板"
        case .invalidGitURL:
            return "Git URL 不能为空"
        case .keychainUnavailable:
            return "Keychain 服务不可用，无法创建 Git 仓库"
        case .gitCloneFailed(let detail):
            return "Git clone 失败: \(detail)"
        }
    }
}

// MARK: - Page 1: Method Selection

/// 选择创建方式页面 — 三个卡片按钮
private struct MethodSelectionPage: View {
    @Binding var selectedMethod: NewProjectWizard.CreationMethod?
    let onSelect: (NewProjectWizard.CreationMethod) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(NewProjectWizard.CreationMethod.allCases) { method in
                    Button(action: { onSelect(method) }) {
                        HStack(spacing: 16) {
                            Image(systemName: method.iconName)
                                .font(.system(size: 28))
                                .foregroundColor(.baizeAccent)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(method.rawValue)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(method.description)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(Color.baizeCardBackground)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

// MARK: - Page 2: Configuration

/// 配置页 — 根据选择的创建方式动态切换
private struct ConfigurationPage: View {
    let method: NewProjectWizard.CreationMethod
    @Binding var projectName: String
    @Binding var selectedTemplate: ProjectTemplate?
    @Binding var gitURL: String
    @Binding var errorMessage: String?
    let existingNames: Set<String>
    let onBack: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // 根据创建方式显示不同配置
            switch method {
            case .empty:
                EmptyProjectConfig(projectName: $projectName)

            case .template:
                TemplateProjectConfig(
                    projectName: $projectName,
                    selectedTemplate: $selectedTemplate
                )

            case .gitClone:
                GitCloneConfig(
                    gitURL: $gitURL,
                    projectName: $projectName
                )
            }

            // 错误消息
            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.baizeError)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.baizeError)
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回", action: onBack)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("创建", action: onCreate)
                    .disabled(!isCreateEnabled)
                    .fontWeight(.semibold)
            }
        }
    }

    /// 创建按钮是否可用
    private var isCreateEnabled: Bool {
        switch method {
        case .empty:
            return !projectName.trimmingCharacters(in: .whitespaces).isEmpty
        case .template:
            return selectedTemplate != nil
                && !projectName.trimmingCharacters(in: .whitespaces).isEmpty
        case .gitClone:
            return !gitURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !projectName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

// MARK: - Empty Project Config

/// 空项目配置 — 输入项目名
private struct EmptyProjectConfig: View {
    @Binding var projectName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("项目名称", systemImage: "folder.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            TextField("my-project", text: $projectName)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            Text("项目将创建在: \(BaizePath.projectRoot)\(projectName)/")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Template Project Config

/// 模板项目配置 — 选择模板 + 输入项目名
private struct TemplateProjectConfig: View {
    @Binding var projectName: String
    @Binding var selectedTemplate: ProjectTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 模板选择
            VStack(alignment: .leading, spacing: 8) {
                Label("选择模板", systemImage: "square.stack.3d.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                ForEach(ProjectTemplate.allCases, id: \.self) { template in
                    Button(action: { selectedTemplate = template }) {
                        HStack(spacing: 12) {
                            Image(systemName: template.iconName)
                                .font(.system(size: 20))
                                .foregroundColor(.baizeAccent)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(template.stackDescription)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if selectedTemplate == template {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.baizeAccent)
                            }
                        }
                        .padding(12)
                        .background(
                            selectedTemplate == template
                                ? Color.baizeAccent.opacity(0.12)
                                : Color.baizeCardBackground
                        )
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selectedTemplate == template
                                        ? Color.baizeAccent.opacity(0.5)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 项目名
            VStack(alignment: .leading, spacing: 8) {
                Label("项目名称", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("my-project", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
    }
}

// MARK: - Git Clone Config

/// Git clone 配置 — 输入 Git URL + 项目名
private struct GitCloneConfig: View {
    @Binding var gitURL: String
    @Binding var projectName: String
    @State private var lastAutoExtractedName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Git 仓库 URL", systemImage: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("https://github.com/user/repo.git", text: $gitURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: gitURL) { newValue in
                        // 从 URL 自动提取项目名
                        // 仅当项目名为空或等于上次自动提取的值时才覆盖（不覆盖用户手动输入）
                        let extracted = extractedName(from: newValue)
                        if projectName.isEmpty || projectName == lastAutoExtractedName {
                            projectName = extracted
                            lastAutoExtractedName = extracted
                        }
                    }

                Text("支持 HTTPS 和 SSH URL")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("项目名称", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("project-name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Text("项目将克隆到: \(BaizePath.projectRoot)\(projectName)/")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    /// 从 Git URL 提取项目名
    /// 例: https://github.com/user/repo.git → repo
    private func extractedName(from url: String) -> String {
        guard !url.isEmpty else { return "" }
        // 去除末尾的 .git
        var cleaned = url
        if cleaned.hasSuffix(".git") {
            cleaned = String(cleaned.dropLast(4))
        }
        // 取最后一级路径
        let lastComponent = (cleaned as NSString).lastPathComponent
        return lastComponent
    }
}

// MARK: - Page 3: Creating

/// 创建中页面 — 进度指示器 + 状态文本
private struct CreatingPage: View {
    let status: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("正在创建项目...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)

            Text(status)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}
