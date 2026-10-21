internal import EditorCore
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// Every user-invokable editor action. Menus, the title-bar menu, the command
/// palette and keyboard shortcuts all resolve to these values.
enum EditorCommand {
    case showCommandPalette(EditorPaletteScope)
    case showSceneSettings
    case showAssets
    case showProblems
    case showPanel(String)
    case maximizePanel(String)
    case restorePanels
    case togglePanelArea(EditorPanelArea)
    /// The activity rail: open the panel, or collapse its group when it is already showing.
    case togglePanel(String)
    case saveLayout
    case closeProject
    case newScene
    case openScene
    case saveScene
    case saveDocument
    case revertDocument
    case closeDocument
    case importAssets
    case undo
    case redo
    case duplicateSelection
    case deleteSelection
    case selectAll
    case clearSelection
    case invertSelection
    case selectDescendants
    case spawnEntity(EditorEntityTemplate)
    case frameSelection
    case toggleSelectionVisibility
    case toggleSelectionLock
    case setWorkspaceMode(EditorWorkspaceMode)
    case setLayoutPreset(EditorLayoutPreset)
    case resetLayout
    case reopenClosedPanel
    case showScripts
    case setPlaybackState(PlaybackState)
    case togglePlayback
    case openSettings
    case toggleTheme
    case buildProject
    case buildAndRun
    case openDocumentation
    case about
}

/// What the unified ⌘K field searches when it opens.
enum EditorPaletteScope: String, CaseIterable {
    /// Plain text is a request for the Agent; commands and resources still match.
    case intent
    case commands
    case resources
    case entities

    var prefix: String {
        switch self {
        case .intent: ""
        case .commands: ">"
        case .resources: "@"
        case .entities: "#"
        }
    }
}

/// A docked edge of the workbench that collapses and expands as a whole.
enum EditorPanelArea: CaseIterable {
    case leading, trailing, bottom
}

extension EditorPaletteScope {
    /// The scope a typed query asks for, read from its leading prefix.
    init(query: String) {
        let raw = query.trimmingCharacters(in: .whitespaces)
        self = Self.allCases.first { !$0.prefix.isEmpty && raw.hasPrefix($0.prefix) } ?? .intent
    }

    var icon: BundleImageResource {
        switch self {
        case .intent: UIIcons.Status.sparkles
        case .commands: UIIcons.Editor.terminal
        case .resources: UIIcons.File.file
        case .entities: UIIcons.Editor.box
        }
    }
}
