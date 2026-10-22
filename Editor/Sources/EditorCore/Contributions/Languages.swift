import Foundation
import PluginRuntime

/// A language a bundled plugin contributes, with the permission that starts its server.
struct ContributedLanguage: Sendable {
    let pluginID: String
    let language: LanguageContribution
    let server: (contribution: LanguageServerContribution, process: PluginProcessPermission)?

    func matches(path: String) -> Bool {
        language.extensions.contains((path as NSString).pathExtension)
    }
}

enum LanguageCatalog {
    static let bundled: [ContributedLanguage] = BundledPlugins.catalog.flatMap { plugin in
        plugin.manifest.contributes.languages.map { language in
            let server = language.server.flatMap { server in
                plugin.manifest.host.processes.first { $0.id == server.process }.map { (server, $0) }
            }
            return ContributedLanguage(pluginID: plugin.id, language: language, server: server)
        }
    }

    /// The language whose server the editor's language session runs.
    static let served: ContributedLanguage? = bundled.first { $0.server != nil }
}
