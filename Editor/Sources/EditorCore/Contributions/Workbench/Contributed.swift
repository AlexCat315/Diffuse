import Foundation
import PluginRuntime

/// A view the host provides for a plugin panel to name.
public enum WorkbenchView: String, Sendable {
    /// The agent conversation, shown only while an agent is enabled.
    case agent
}

/// One enabled `cove.command/v1` contribution.
public struct ContributedCommand: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let title: String
    public let keywords: String
    public let showsInPalette: Bool
    /// The identifier within its package, which the package's panels use.
    public let name: String
    let entryPoint: String

    /// Unique across packages, so two packages may both name a command `refresh`.
    public var id: String { pluginID + "." + name }

    init(pluginID: String, contribution: CommandContribution) {
        self.pluginID = pluginID
        title = contribution.title
        keywords = contribution.keywords ?? ""
        showsInPalette = contribution.palette ?? true
        name = contribution.id
        entryPoint = contribution.entryPoint
    }
}

/// One enabled `cove.ui.panel/v1` contribution.
public struct ContributedPanel: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case view(WorkbenchView)
        /// The plugin describes the content as a ``PanelModel``.
        case model
    }

    public let pluginID: String
    /// The workspace panel identifier; unique among enabled packages.
    public let id: String
    public let title: String
    public let slot: String
    public let icon: String?
    public let content: Content
    let entryPoint: String?

    init?(pluginID: String, contribution: PanelContribution) {
        switch contribution.content {
        case let .view(name):
            guard let view = WorkbenchView(rawValue: name) else { return nil }
            content = .view(view)
            entryPoint = nil
        case let .entryPoint(entryPoint):
            content = .model
            self.entryPoint = entryPoint
        }
        self.pluginID = pluginID
        id = contribution.id
        title = contribution.title
        slot = contribution.slot ?? "trailing"
        icon = contribution.icon
    }
}

/// Everything enabled packages add to the workbench, for one editor session.
public struct WorkbenchCatalog: Sendable, Equatable {
    public let commands: [ContributedCommand]
    public let panels: [ContributedPanel]
    public let menuItems: [ContributedMenuItem]
    public let toolbarItems: [ContributedToolbarItem]
    public let documentViews: [ContributedDocumentView]

    public static let empty = WorkbenchCatalog(packages: [])

    /// Each package contributes whatever workbench points it declares.
    public init(packages: [ValidatedPluginPackage]) {
        let packages = packages.sorted { $0.manifest.id < $1.manifest.id }
        func decode<Point: ContributionPointSpec, Value>(_ point: Point.Type,
                                                         _ make: (String, Point.Descriptor) -> Value?) -> [Value] {
            packages.flatMap { package in
                ((try? package.manifest.contributes.decode(point)) ?? []).compactMap { make(package.manifest.id, $0) }
            }
        }
        let commands = decode(CommandContributionPoint.self, ContributedCommand.init)
        func command(_ pluginID: String, _ name: String) -> ContributedCommand? {
            commands.first { $0.pluginID == pluginID && $0.name == name }
        }
        self.commands = commands
        panels = decode(PanelContributionPoint.self, ContributedPanel.init)
        menuItems = decode(MenuContributionPoint.self) { pluginID, item in
            command(pluginID, item.command).map { ContributedMenuItem(command: $0, menu: item.menu) }
        }
        toolbarItems = decode(ToolbarContributionPoint.self) { pluginID, item in
            command(pluginID, item.command).map { ContributedToolbarItem(command: $0, icon: item.icon) }
        }
        documentViews = decode(DocumentViewContributionPoint.self, ContributedDocumentView.init)
    }

    public func command(pluginID: String, name: String) -> ContributedCommand? {
        commands.first { $0.pluginID == pluginID && $0.name == name }
    }

    public func panel(id: String) -> ContributedPanel? {
        panels.first { $0.id == id }
    }

    /// The panel that shows a host view, such as the agent conversation.
    public func panel(view: WorkbenchView) -> ContributedPanel? {
        panels.first { $0.content == .view(view) }
    }

    /// The views a document at `path` can be shown in besides its text.
    public func documentViews(forPath path: String) -> [ContributedDocumentView] {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? [] : documentViews.filter { $0.extensions.contains(ext) }
    }

    func commandIDs(pluginID: String) -> Set<String> {
        Set(commands.filter { $0.pluginID == pluginID }.map(\.name))
    }

    func panelIDs(pluginID: String) -> Set<String> {
        Set(panels.filter { $0.pluginID == pluginID }.map(\.id))
    }
}
