import Foundation
import PluginRuntime

/// A panel an agent package adds. The host renders it; the package only names
/// it, so disabling the package removes the panel with no residue.
public struct AgentPanelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let slot: String
    public let icon: String?

    public init(id: String, title: String, slot: String = "trailing", icon: String? = nil) {
        self.id = id
        self.title = title
        self.slot = slot
        self.icon = icon
    }
}

/// One enabled agent contribution, narrowed to what the workbench needs.
public struct AgentDescriptor: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let id: String
    public let title: String
    public let panels: [AgentPanelDescriptor]
    public let defaultModel: String?
    public let canAutoApprove: Bool

    public init(pluginID: String, contribution: AgentContribution) {
        self.pluginID = pluginID
        id = contribution.id
        title = contribution.title
        panels = contribution.panels.map {
            AgentPanelDescriptor(id: $0.id, title: $0.title,
                                 slot: $0.slot ?? "trailing", icon: $0.icon)
        }
        defaultModel = contribution.defaultModel
        canAutoApprove = contribution.canAutoApprove ?? true
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

    /// The panel an agent declares for the assistant surface.
    public func panel(id: String) -> (agent: AgentDescriptor, panel: AgentPanelDescriptor)? {
        for agent in agents {
            if let panel = agent.panels.first(where: { $0.id == id }) { return (agent, panel) }
        }
        return nil
    }
}
