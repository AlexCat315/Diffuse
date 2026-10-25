internal import EditorCore
internal import GuavaUI
internal import GuavaUICompose

/// Where the assistant shows in one window: a composer floating under the
/// content, a thread that opens above it, or a column pinned to the right.
/// The draft is shared, so switching between them keeps what was typed.
final class EditorAssistantSurface: _ObservableObject {
    struct State: Equatable {
        var isOpen = false
        var isPinned = false
        /// Bumped to put the caret in the composer.
        var focusRequest: UInt64 = 0
    }

    private(set) var state = State()
    var draft: TextBuffer = ""
    /// Rebuilds the layout when the pinned column comes or goes. Installed by the shell.
    var relayout: (@MainActor () -> Void)?
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

    func open() { update { $0.isOpen = true } }
    func close() { update { $0.isOpen = false } }
    func focus() { update { $0.focusRequest &+= 1 } }

    func setPinned(_ pinned: Bool) {
        guard pinned != state.isPinned else { return }
        update {
            $0.isPinned = pinned
            $0.isOpen = !pinned && $0.isOpen
        }
        let relayout = relayout
        MainActor.assumeIsolated { relayout?() }
    }

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
