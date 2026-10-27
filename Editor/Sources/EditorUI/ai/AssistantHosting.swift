internal import EditorCore
internal import CoveUI

/// What the agent UI needs from whatever owns a conversation.
///
/// Two things own one: a project's `EditorApplication`, and the standalone host
/// the window uses when no project is open. Neither is the agent itself — the
/// agent comes from the plugin catalog — so the UI must not reach for
/// `EditorApplication` directly.
///
/// Deliberately not `@MainActor`: the view bodies that read these are
/// nonisolated, exactly as they were when they took `EditorApplication`.
/// One segment of the window's view switch.
struct EditorStudioViewSegment: Hashable {
    let view: EditorStudioView
    let title: String
    let icon: String?
}

/// The top-level views this editor knows how to draw.
///
/// `cove.ui.panel/v1` lets a package name any view, but naming one is only a
/// placement: something has to render it. A package that wants a whole view of
/// its own contributes a model panel instead, which needs nothing here. A name
/// the editor cannot draw stays an ordinary panel, so the window never offers a
/// segment that shows nothing.

protocol AssistantHosting: AnyObject, Sendable {
    var store: EditorStore { get }
    /// The view state (workbench / agent, canvas, draft) for this conversation.
    var assistantSurface: EditorAssistantSurface { get }
    /// The top-level views this window can show: the workbench, plus every view
    /// an enabled package declared a panel for. Nothing here asks "is plugin X
    /// enabled" — a package contributes a view or it does not.
    var studioViews: [EditorStudioView] { get }
    var studioViewSegments: [EditorStudioViewSegment] { get }
    /// Whether any enabled package contributes an agent to talk to. This is a
    /// capability question, separate from whether a view exists.
    var isAgentEnabled: Bool { get }
    var isAIAvailable: Bool { get }
    /// Scene edits are only allowed while authoring; a host without a scene is
    /// always authoring.
    var isSceneAuthoringEnabled: Bool { get }
    /// Nil when the host has no project: there is no document workspace then.
    var documents: EditorDocumentWorkspace? { get }

    @discardableResult
    func submitNaturalLanguageIntent(_ text: String) -> Bool
    func cancelAgentTask()
    func openAssistantSettings()
}

extension AssistantHosting {
    func hasStudioView(_ view: EditorStudioView) -> Bool { studioViews.contains(view) }
}

extension EditorApplication: AssistantHosting {
    var assistantSurface: EditorAssistantSurface { EditorAssistantSurface.of(self) }
    var documents: EditorDocumentWorkspace? { workstation.documents }
    func openAssistantSettings() { openSettingsWindow() }

    /// The workbench, then one view per panel a package declared for a host
    /// view. A package that stops contributing the panel takes its view with it.
    var studioViews: [EditorStudioView] {
        [.make] + workbenchCatalog.panels.compactMap { panel -> EditorStudioView? in
            if let surface = panel.surface { return EditorStudioView(panel.pluginID + "." + surface) }
            return nil
        }
    }

    var studioViewSegments: [EditorStudioViewSegment] {
        var segments = [EditorStudioViewSegment(view: .make, title: L("Workbench"), icon: nil)]
        for panel in workbenchCatalog.panels {
            if let surface = panel.surface {
                segments.append(EditorStudioViewSegment(view: EditorStudioView(panel.pluginID + "." + surface), title: panel.title, icon: panel.icon))
                continue
            }

        }
        return segments
    }
}
