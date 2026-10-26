internal import EditorCore
internal import CoveUI
internal import CoveUICompose

/// Who is doing the work decides the window: you, in the canvas, or the agent,
/// in the conversation. Both views share one project, its files and selection.
enum EditorStudioView: Hashable {
    case make
    case agent
}

/// The agent side of one window: which view is in front and the shared draft.
final class EditorAssistantSurface: _ObservableObject {
    /// What the agent view shows beside the thread.
    enum Canvas: Hashable {
        /// Whatever the agent is working on, nothing until it starts.
        case follow
        case hidden
        case content(EditorContent)
    }

    struct State: Equatable {
        /// A window opens on the agent view, as Codex does; the workbench is one switch away.
        var view: EditorStudioView = .agent
        var canvas: Canvas = .follow
        /// Bumped to put the caret in the composer.
        var focusRequest: UInt64 = 0
    }

    private(set) var state = State()
    var draft: TextBuffer = ""
    private let publisher = _ObservablePublisher<EditorAssistantSurface>()

    nonisolated(unsafe) private static var byApplication: [ObjectIdentifier: EditorAssistantSurface] = [:]

    /// One surface per project window.
    static func of(_ app: EditorApplication) -> EditorAssistantSurface {
        let key = ObjectIdentifier(app)
        if let existing = byApplication[key] { return existing }
        let created = EditorAssistantSurface()
        byApplication[key] = created
        return created
    }

    /// A closed project's object identifier can be reused by the next project.
    static func release(_ app: EditorApplication) { byApplication[ObjectIdentifier(app)] = nil }

    func show(_ view: EditorStudioView) { update { $0.view = view } }
    func showCanvas(_ canvas: Canvas) { update { $0.canvas = canvas } }
    func toggleView() { show(state.view == .make ? .agent : .make) }
    /// The composer lives in the agent view, so asking brings it to the front.
    func focus() { update { $0.view = .agent; $0.focusRequest &+= 1 } }

    private func update(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        publisher.send()
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
