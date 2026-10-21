internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

enum SettingsCategory: String, CaseIterable, Sendable {
    case general, editor, agent, plugins, shortcuts, about

    var title: String {
        let key = switch self {
        case .general: "General"
        case .editor: "Editor"
        case .agent: "Agent"
        case .plugins: "Extensions"
        case .shortcuts: "Keyboard Shortcuts"
        case .about: "About Guava"
        }
        return L(key)
    }

    var summary: String {
        let key = switch self {
        case .general: "Make this workspace feel like yours."
        case .editor: "Fine-tune how you work with the scene."
        case .agent: "Connect your assistant and choose how it works with you."
        case .plugins: "Manage built-in and added plugins and the access they get."
        case .shortcuts: "The shortcuts available in your current Space."
        case .about: "Your workspace, application, and support information."
        }
        return L(key)
    }

    var icon: BundleImageResource {
        switch self {
        case .general: UIIcons.Action.settings
        case .editor: UIIcons.Editor.box
        case .agent: UIIcons.Status.sparkles
        case .plugins: UIIcons.File.package
        case .shortcuts: UIIcons.Editor.code
        case .about: UIIcons.Status.info
        }
    }
}

enum SettingsSectionID: String, CaseIterable, Sendable {
    case appearance, language, selection, display, provider, execution, capabilities, plugins, shortcuts, about

    var category: SettingsCategory {
        switch self {
        case .appearance, .language: .general
        case .selection, .display: .editor
        case .provider, .execution, .capabilities: .agent
        case .plugins: .plugins
        case .shortcuts: .shortcuts
        case .about: .about
        }
    }

    var title: String {
        let key = switch self {
        case .appearance: "Appearance"
        case .language: "Language"
        case .selection: "Selection"
        case .display: "Display & Performance"
        case .provider: "Provider & Credentials"
        case .execution: "Execution & Review"
        case .capabilities: "Capability Gate"
        case .plugins: "Plugins"
        case .shortcuts: "Keyboard Shortcuts"
        case .about: "Workspace Information"
        }
        return L(key)
    }

    private var keywords: String {
        switch self {
        case .appearance: "appearance theme dark light color 外观 主题 深色 浅色 颜色"
        case .language: "language locale english chinese system 语言 中文 英文 系统"
        case .selection: "selection subtract toggle command control modifier 选择 减选 切换 修饰键"
        case .display: "display performance vertical sync vsync fps refresh 显示 性能 垂直 同步 刷新"
        case .provider: "agent assistant ai provider model api key credential anthropic openai deepseek 模型 密钥 凭据 服务商 智能体"
        case .execution: "agent approval auto approve safe review 自动 确认 审阅 执行"
        case .capabilities: "capability gate stable beta experimental permissions 能力 稳定 测试 实验 权限"
        case .plugins: "plugin extension authorize revoke reload disable 插件 扩展 授权 撤销 重载 禁用"
        case .shortcuts: "keyboard shortcut key binding 快捷键 键盘 按键"
        case .about: "about version project diagnostics support 关于 版本 项目 诊断 支持"
        }
    }

    func matches(_ query: String) -> Bool {
        let haystack = "\(category.title) \(title) \(keywords)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.localizedStandardContains(String($0))
        }
    }

    static func visible(category: SettingsCategory, query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.filter { query.isEmpty ? $0.category == category : $0.matches(query) }
    }
}
