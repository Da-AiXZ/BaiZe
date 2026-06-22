import Foundation
import SwiftUI

// MARK: - Project Entry Model

/// 项目入口数据模型 — 持久化项目列表
/// Codable + Identifiable，iconColor 为 computed property（不持久化 Color）
struct ProjectEntry: Codable, Identifiable {
    /// 唯一标识
    let id: UUID
    /// 项目名称
    var name: String
    /// 项目绝对路径
    var path: String
    /// 技术栈描述
    var stack: String
    /// SF Symbol 图标名
    var icon: String
    /// 最后打开时间
    var lastOpened: Date

    /// 从 icon 名推导颜色（computed property，不参与 Codable 编解码）
    /// 参考 DashboardView.swift 旧 ProjectEntry 的 iconColor 用法
    var iconColor: Color {
        switch icon {
        case "swift", "swiftui":
            return .baizeWarning
        case "globe", "network", "safari", "safari.fill":
            return .baizePrimaryLight
        case "chart.bar.fill", "chart.xyaxis.line", "chart.line.uptrend.xyaxis":
            return .baizeAccent
        case "terminal", "chevron.left.forwardslash.chevron.right":
            return .baizeSuccess
        case "doc.text", "doc.text.fill", "doc.richtext":
            return .baizeTextSecondary
        case "folder", "folder.fill":
            return .baizeAccent
        case "hammer", "hammer.fill", "wrench":
            return .baizeWarning
        case "gear", "gearshape", "gearshape.fill":
            return .baizeTextSecondary
        case "python":
            return .baizeAccent
        case "nodejs", "node":
            return .baizeSuccess
        case "html":
            return .baizePrimaryLight
        default:
            return .baizeAccent
        }
    }

    /// Mock 项目数据（供 Dashboard 占位使用，T03 将替换为 ProjectRegistry 真实数据）
    static let mockProjects: [ProjectEntry] = [
        ProjectEntry(
            id: UUID(),
            name: "my-app",
            path: "/var/mobile/Documents/Baize/my-app",
            stack: "React + TypeScript",
            icon: "globe",
            lastOpened: Date().addingTimeInterval(-120)
        ),
        ProjectEntry(
            id: UUID(),
            name: "baize-core",
            path: "/var/mobile/Documents/Baize/baize-core",
            stack: "Swift + SwiftUI",
            icon: "swift",
            lastOpened: Date().addingTimeInterval(-3600)
        ),
        ProjectEntry(
            id: UUID(),
            name: "data-pipeline",
            path: "/var/mobile/Documents/Baize/data-pipeline",
            stack: "Python + pandas",
            icon: "chart.bar.fill",
            lastOpened: Date().addingTimeInterval(-86400)
        ),
    ]
}

// MARK: - Project Registry

/// 项目注册表 — 持久化项目列表到 BaizePath.projectsRegistry
/// actor 隔离保证并发安全，JSON 持久化模式与 ConversationStore 一致
actor ProjectRegistry {

    // MARK: - Properties

    /// 内存中的项目列表
    private var projects: [ProjectEntry]

    /// 持久化文件路径（BaizePath.projectsRegistry）
    private let storePath: String

    /// FileManager 实例
    private let fileManager = FileManager.default

    // MARK: - Initialization

    /// 初始化项目注册表
    /// - Parameter storePath: 持久化文件路径，默认为 BaizePath.projectsRegistry
    init(storePath: String = BaizePath.projectsRegistry) {
        self.storePath = storePath
        self.projects = []
    }

    // MARK: - Public API

    /// 启动时加载项目列表，文件不存在返回空数组
    /// - Returns: 加载后的项目列表
    @discardableResult
    func load() -> [ProjectEntry] {
        guard fileManager.fileExists(atPath: storePath) else {
            agentLogger.info("ProjectRegistry: no registry file found, starting with empty list")
            projects = []
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([ProjectEntry].self, from: data)
            agentLogger.info("ProjectRegistry: loaded \(self.projects.count) projects")
            return self.projects
        } catch {
            agentLogger.error("ProjectRegistry: failed to load registry: \(error.localizedDescription)")
            projects = []
            return []
        }
    }

    /// 按 lastOpened 降序返回项目列表
    /// - Returns: 按 lastOpened 降序排列的项目列表
    func list() -> [ProjectEntry] {
        projects.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// 添加新项目到注册表
    /// - Parameter entry: 项目入口数据
    func add(_ entry: ProjectEntry) {
        // 避免重复添加同路径项目
        if projects.contains(where: { $0.path == entry.path }) {
            agentLogger.info("ProjectRegistry: project at path \(entry.path) already registered, skipping")
            return
        }
        projects.append(entry)
        save()
        agentLogger.info("ProjectRegistry: added project '\(entry.name)' at \(entry.path)")
    }

    /// 仅从注册表删除，不删除文件系统中的项目文件
    /// - Parameter id: 项目 UUID
    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
        agentLogger.info("ProjectRegistry: removed project with id \(id.uuidString)")
    }

    /// 更新项目信息（如 lastOpened、name 等）
    /// - Parameter entry: 更新后的项目入口数据
    func update(_ entry: ProjectEntry) {
        if let index = projects.firstIndex(where: { $0.id == entry.id }) {
            projects[index] = entry
            save()
            agentLogger.info("ProjectRegistry: updated project '\(entry.name)'")
        } else {
            agentLogger.info("ProjectRegistry: project \(entry.id.uuidString) not found, adding as new")
            projects.append(entry)
            save()
        }
    }

    /// 按路径查找项目
    /// - Parameter path: 项目绝对路径
    /// - Returns: 匹配的项目，未找到返回 nil
    func find(path: String) -> ProjectEntry? {
        projects.first { $0.path == path }
    }

    // MARK: - Private

    /// 持久化项目列表到 JSON 文件
    /// 使用 .iso8601 日期策略 + .atomic 原子写入（与 ConversationStore 一致）
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(projects)

            // 确保父目录存在
            let parentDir = (storePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        } catch {
            agentLogger.error("ProjectRegistry: failed to save registry: \(error.localizedDescription)")
        }
    }
}
