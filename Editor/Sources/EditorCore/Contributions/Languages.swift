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

public struct LanguageCatalog: Sendable {
    /// File recognition outside a project uses immutable bundled metadata.
    public static let bundled = LanguageCatalog(packages: BundledPlugins.catalog.compactMap {
        try? PluginPackageLoader().load(at: $0.package)
    })
    static let served = bundled.languages.first { $0.server != nil }
    let languages: [ContributedLanguage]

    init(packages: [ValidatedPluginPackage] = []) {
        languages = packages.sorted { $0.manifest.id < $1.manifest.id }.flatMap { package in
            ((try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).map {
                ContributedLanguage(pluginID: package.manifest.id, language: $0,
                    server: Self.server(of: $0, in: package.manifest))
            }
        }
    }

    /// Whether any enabled package contributes a language service. The UI asks
    /// this instead of naming a plugin, so a different package can serve the
    /// language without any editor change.
    public var hasLanguageService: Bool { languages.contains { $0.server != nil } }

    public func descriptor(forExtension ext: String) -> LanguageDescriptor? {
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

    public func syntaxRules(forLanguageID id: String?) -> [LanguageSyntaxRule] {
        guard let language = language(id: id), let grammar = language.language.grammar else { return [] }
        return grammar.rules.compactMap { rule in
            guard let token = LanguageSyntaxRule.Token(rawValue: rule.token) else { return nil }
            return LanguageSyntaxRule(pattern: rule.pattern, token: token)
        }
    }

    public func outlineRules(forLanguageID id: String?) -> [LanguageOutlineRule] {
        guard let language = language(id: id), let outline = language.language.outline else { return [] }
        return outline.rules.map { LanguageOutlineRule(pattern: $0.pattern, level: $0.level) }
    }

    public func format(forLanguageID id: String?) -> LanguageFormat? {
        guard let language = language(id: id), let format = language.language.format else { return nil }
        return LanguageFormat(pluginID: language.pluginID, entryPoint: format.entryPoint)
    }

    private func language(id: String?) -> ContributedLanguage? {
        guard let id else { return nil }
        return languages.first { $0.language.id == id }
    }

    private static func server(of language: LanguageContribution,
                               in manifest: CovePluginManifest)
    -> (contribution: LanguageServerContribution, process: PluginProcessPermission)? {
        language.server.flatMap { server in
            manifest.host.processes.first { $0.id == server.process }.map { (server, $0) }
        }
    }
}
