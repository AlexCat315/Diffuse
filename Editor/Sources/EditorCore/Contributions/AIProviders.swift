import Foundation
import PluginRuntime

/// A model a provider exposes. The host owns transport; the descriptor only
/// tells the editor what can be selected.
public struct AIModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let supportsTools: Bool

    public init(id: String, title: String, contextWindow: Int? = nil,
                maxOutputTokens: Int? = nil, supportsTools: Bool = true) {
        self.id = id
        self.title = title
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
    }
}

public struct AIAuthFieldDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let isSecret: Bool
    public let environmentVariable: String?

    public init(id: String, title: String, isSecret: Bool, environmentVariable: String?) {
        self.id = id
        self.title = title
        self.isSecret = isSecret
        self.environmentVariable = environmentVariable
    }
}

/// One enabled or bundled AI provider contribution, narrowed to the values the
/// settings UI and session factory need.
public struct AIProviderDescriptor: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let id: String
    public let title: String
    public let apiFormat: String
    public let baseURL: String?
    public let defaultModel: String
    public let models: [AIModelDescriptor]
    public let authFields: [AIAuthFieldDescriptor]

    /// The field whose value the session sends as the API key.
    public var secretField: AIAuthFieldDescriptor? {
        authFields.first { $0.isSecret }
    }

    public init(pluginID: String, contribution: AIProviderContribution) {
        self.pluginID = pluginID
        id = contribution.id
        title = contribution.title
        apiFormat = contribution.apiFormat
        baseURL = contribution.baseURL
        models = contribution.models.map {
            AIModelDescriptor(id: $0.id, title: $0.title,
                              contextWindow: $0.contextWindow,
                              maxOutputTokens: $0.maxOutputTokens,
                              supportsTools: $0.supportsTools ?? true)
        }
        defaultModel = contribution.defaultModel ?? models.first?.id ?? ""
        authFields = (contribution.auth?.fields ?? []).map {
            AIAuthFieldDescriptor(id: $0.id, title: $0.title,
                                  isSecret: $0.secret ?? true,
                                  environmentVariable: $0.environmentVariable)
        }
    }
}

/// Immutable domain snapshot. Every editor session owns its enabled providers.
public struct AIProviderCatalog: Sendable {
    public let providers: [AIProviderDescriptor]

    public static let bundled = AIProviderCatalog(packages: BundledPlugins.catalog.compactMap {
        try? PluginPackageLoader().load(at: $0.package)
    })

    init(packages: [ValidatedPluginPackage] = []) {
        providers = packages.sorted { $0.manifest.id < $1.manifest.id }.flatMap { package in
            ((try? package.manifest.contributes.decode(AIProviderContributionPoint.self)) ?? []).map {
                AIProviderDescriptor(pluginID: package.manifest.id, contribution: $0)
            }
        }
    }

    public func provider(id: String) -> AIProviderDescriptor? { providers.first { $0.id == id } }
    public func model(providerID: String, modelID: String) -> AIModelDescriptor? {
        provider(id: providerID)?.models.first { $0.id == modelID }
    }
    public func defaultModel(for providerID: String) -> String? { provider(id: providerID)?.defaultModel }
}
