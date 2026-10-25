import AIRuntime
import Foundation
import PluginRuntime

/// One enabled agent contribution, narrowed to what the session needs.
public struct AgentDescriptor: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let id: String
    public let title: String
    public let instructions: String?
    public let preferredModel: String?
    public let maxOutputTokens: Int?
    /// Nil means every tool the workspace allows.
    public let tools: Set<String>?
    /// Nil means every host source and no package context.
    public let context: Set<String>?
    public let canAutoApprove: Bool
    /// The `guava.ai.harness/v1` running this agent's turns; nil for the built-in loop.
    public let harness: String?

    public init(pluginID: String, contribution: AgentContribution) {
        self.pluginID = pluginID
        id = contribution.id
        title = contribution.title
        instructions = contribution.instructions
        preferredModel = contribution.model?.preferred
        maxOutputTokens = contribution.model?.maxOutputTokens
        tools = contribution.tools.map(Set.init)
        context = contribution.context.map(Set.init)
        canAutoApprove = contribution.canAutoApprove ?? true
        harness = contribution.harness
    }

    /// The host sources the agent keeps; a name that is no host source is a package context.
    var hostSources: Set<SessionContextSource>? {
        context.map { Set($0.compactMap(SessionContextSource.init(rawValue:))) }
    }

    var packageContexts: Set<String> {
        (context ?? []).filter { SessionContextSource(rawValue: $0) == nil }
    }
}

/// Enabled agents for one editor session. Empty means the editor has no
/// assistant surface at all: no panel, no command, no status entry.
public struct AgentCatalog: Sendable, Equatable {
    public let agents: [AgentDescriptor]

    public static let empty = AgentCatalog(agents: [])

    public init(agents: [AgentDescriptor] = []) {
        self.agents = agents
    }

    public init(packages: [ValidatedPluginPackage]) {
        agents = packages.sorted { $0.manifest.id < $1.manifest.id }.flatMap { package in
            ((try? package.manifest.contributes.decode(AgentContributionPoint.self)) ?? []).map {
                AgentDescriptor(pluginID: package.manifest.id, contribution: $0)
            }
        }
    }

    public var isEmpty: Bool { agents.isEmpty }
    public var isEnabled: Bool { !agents.isEmpty }

    /// The chosen agent, or the first when the choice is empty or gone.
    public func agent(id: String) -> AgentDescriptor? {
        agents.first { $0.id == id } ?? agents.first
    }
}
