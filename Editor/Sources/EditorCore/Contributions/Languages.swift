import Foundation
import PluginRuntime

/// A language a plugin contributes, with the permission that starts its server.
struct ContributedLanguage: Sendable {
    let pluginID: String
    let language: LanguageContribution
    let server: (contribution: LanguageServerContribution, process: PluginProcessPermission)?

    var iconKey: String { language.icon ?? language.id }

    func matches(path: String) -> Bool {
        language.extensions.contains((path as NSString).pathExtension)
    }
}

/// A language's user-facing identity: what a document path looks like, without
/// the plugin or server details behind it.
public struct LanguageDescriptor: Sendable, Equatable {
    public let id: String
    public let title: String
    public let extensions: [String]
    public let iconKey: String
}

/// One declarative colouring rule, already narrowed to the host's token set.
public struct LanguageSyntaxRule: Sendable, Equatable {
    public enum Token: String, Sendable {
        case keyword, type, function, string, number, comment, attribute, directive
    }

    public let pattern: String
    public let token: Token

    public init(pattern: String, token: Token) {
        self.pattern = pattern
        self.token = token
    }
}

/// One declarative heading rule: capture group 1 is the title.
public struct LanguageOutlineRule: Sendable, Equatable {
    public let pattern: String
    public let level: Int

    public init(pattern: String, level: Int) {
        self.pattern = pattern
        self.level = level
    }
}

/// The enabled package and entry point that format this language.
public struct LanguageFormat: Sendable, Equatable {
    public let pluginID: String
    public let entryPoint: String

    public init(pluginID: String, entryPoint: String) {
        self.pluginID = pluginID
        self.entryPoint = entryPoint
    }
}

public enum LanguageCatalog {
    /// Every language a bundled package contributes, whether enabled or not:
    /// recognising a file does not require its language service to run.
    static let bundled: [ContributedLanguage] = BundledPlugins.catalog.flatMap(contributed)

    /// The language whose server the editor's language session runs.
    static let served: ContributedLanguage? = bundled.first { $0.server != nil }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registered: [ContributedLanguage] = bundled

    /// Bundled languages, then those of enabled plugins, one entry per language id.
    static var languages: [ContributedLanguage] {
        registryLock.withLock { registered }
    }

    /// Refreshes the registry after a plugin mounts or unmounts. Bundled
    /// contributions keep precedence, so an enabled bundled package does not
    /// register itself twice.
    static func update(bindings: [String: PluginExecutionBinding], packages: [ValidatedPluginPackage] = []) {
        var merged = bundled
        var seen = Set(bundled.map(\.language.id))
        for pluginID in bindings.keys.sorted() {
            guard let binding = bindings[pluginID] else { continue }
            for language in contributed(binding).map(\.language)
            where seen.insert(language.id).inserted {
                merged.append(ContributedLanguage(pluginID: pluginID, language: language,
                                                  server: server(of: language, in: binding.inspection.manifest)))
            }
        }
        for package in packages {
            for language in (try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []
            where seen.insert(language.id).inserted {
                merged.append(ContributedLanguage(pluginID: package.manifest.id, language: language,
                                                  server: server(of: language, in: package.manifest)))
            }
        }
        registryLock.withLock { registered = merged }
    }

    public static func descriptor(forExtension ext: String) -> LanguageDescriptor? {
        let ext = ext.lowercased()
        guard !ext.isEmpty,
              let language = languages.first(where: { $0.language.extensions.contains(ext) }) else {
            return nil
        }
        return LanguageDescriptor(id: language.language.id,
                                 title: language.language.title,
                                 extensions: language.language.extensions,
                                 iconKey: language.iconKey)
    }

    public static func syntaxRules(forLanguageID id: String?) -> [LanguageSyntaxRule] {
        guard let language = language(id: id), let grammar = language.language.grammar else { return [] }
        return grammar.rules.compactMap { rule in
            guard let token = LanguageSyntaxRule.Token(rawValue: rule.token) else { return nil }
            return LanguageSyntaxRule(pattern: rule.pattern, token: token)
        }
    }

    public static func outlineRules(forLanguageID id: String?) -> [LanguageOutlineRule] {
        guard let language = language(id: id), let outline = language.language.outline else { return [] }
        return outline.rules.map { LanguageOutlineRule(pattern: $0.pattern, level: $0.level) }
    }

    public static func format(forLanguageID id: String?) -> LanguageFormat? {
        guard let language = language(id: id), let format = language.language.format else { return nil }
        return LanguageFormat(pluginID: language.pluginID, entryPoint: format.entryPoint)
    }

    private static func language(id: String?) -> ContributedLanguage? {
        guard let id else { return nil }
        return languages.first { $0.language.id == id }
    }

    private static func contributed(_ plugin: BundledPlugin) -> [ContributedLanguage] {
        ((try? plugin.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).map { language in
            ContributedLanguage(pluginID: plugin.id, language: language,
                                server: server(of: language, in: plugin.manifest))
        }
    }

    private static func contributed(_ binding: PluginExecutionBinding) -> [ContributedLanguage] {
        ((try? binding.inspection.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).map { language in
            ContributedLanguage(pluginID: binding.pluginID, language: language,
                                server: server(of: language, in: binding.inspection.manifest))
        }
    }

    private static func server(of language: LanguageContribution,
                               in manifest: GuavaPluginManifest)
    -> (contribution: LanguageServerContribution, process: PluginProcessPermission)? {
        language.server.flatMap { server in
            manifest.host.processes.first { $0.id == server.process }.map { (server, $0) }
        }
    }
}
