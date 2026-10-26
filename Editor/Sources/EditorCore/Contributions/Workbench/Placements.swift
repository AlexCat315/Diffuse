import Foundation
import PluginRuntime

/// A package command placed at the end of a host menu.
public struct ContributedMenuItem: Sendable, Equatable {
    public let command: ContributedCommand
    /// One of ``MenuContribution/menus``.
    public let menu: String
}

/// A package command shown as an icon button on the title bar.
public struct ContributedToolbarItem: Sendable, Equatable {
    public let command: ContributedCommand
    /// The name of one of the host's toolbar icons.
    public let icon: String
}

/// One enabled `cove.ui.documentView/v1` contribution.
public struct ContributedDocumentView: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let id: String
    public let title: String
    public let extensions: [String]
    let entryPoint: String

    init(pluginID: String, contribution: DocumentViewContribution) {
        self.pluginID = pluginID
        id = contribution.id
        title = contribution.title
        extensions = contribution.extensions
        entryPoint = contribution.entryPoint
    }
}
