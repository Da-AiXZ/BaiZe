import Foundation

// MARK: - Project Template

/// 项目模板枚举 — 定义可创建的项目类型
/// 本枚举仅定义元数据，实际模板文件由 Xcode 项目配置添加到 App Bundle（T03 处理）
enum ProjectTemplate: String, CaseIterable {
    /// React + Vite + TypeScript
    case reactVite
    /// Swift Package
    case swiftPackage
    /// Python
    case python
    /// Node.js
    case nodejs
    /// 静态 HTML
    case staticHTML

    /// 显示名称
    var displayName: String {
        switch self {
        case .reactVite: return "React + Vite"
        case .swiftPackage: return "Swift Package"
        case .python: return "Python"
        case .nodejs: return "Node.js"
        case .staticHTML: return "静态 HTML"
        }
    }

    /// SF Symbol 图标名
    var iconName: String {
        switch self {
        case .reactVite: return "globe"
        case .swiftPackage: return "swift"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .nodejs: return "terminal"
        case .staticHTML: return "doc.text"
        }
    }

    /// 技术栈描述
    var stackDescription: String {
        switch self {
        case .reactVite: return "React + TypeScript + Vite"
        case .swiftPackage: return "Swift Package Manager"
        case .python: return "Python 3.13"
        case .nodejs: return "Node.js + npm"
        case .staticHTML: return "HTML + CSS + JavaScript"
        }
    }

    /// App Bundle 中模板目录名
    var bundleDirectoryName: String {
        switch self {
        case .reactVite: return "templates/react-vite"
        case .swiftPackage: return "templates/swift-package"
        case .python: return "templates/python"
        case .nodejs: return "templates/nodejs"
        case .staticHTML: return "templates/static-html"
        }
    }
}
