internal import EditorCore
internal import CoveUI
internal import CoveUICompose

/// A top-level view a window can be in.
///
/// The workbench is the editor's own. Every other view exists because an
/// enabled package declared a panel for it — the identity is the name the
/// package used, so no plugin needs its own `isXxxEnabled` flag.
struct EditorStudioView: Hashable {
    let id: String

    init(_ id: String) { self.id = id }

    static let make = EditorStudioView("make")
    /// The agent conversation, named exactly as a package names it.
    static let agent = EditorStudioView(WorkbenchView.agent.rawValue)
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
        struct Regions: Equatable {
            var leading = true
            var trailing = false
            var selectedPanels: [String: String] = [:]
        }
        var regions: [EditorStudioView: Regions] = [:]
        /// A window opens on the agent view, as Codex does; the workbench is one switch away.
        fileprivate(set) var requestedView: EditorStudioView = .agent
        var canvas: Canvas = .follow
        /// Bumped to put the caret in the composer.
        var focusRequest: UInt64 = 0
        /// False while the window's packages are still registering. The editor
        /// is held back until then, so the first frame is the view the window
        /// is actually going to stay on instead of the workbench it falls back
        /// to while no package has contributed anything yet.
        fileprivate(set) var isReady = true
    }

    private(set) var state = State()
    var draft: TextBuffer = ""
    /// The views the window can show right now, read through the host. A view a
    /// package stopped contributing is gone; nothing here knows which plugin
    /// that was.
    private var availableViews: () -> [EditorStudioView] = { [.make] }

    /// The view actually in front. A request for a view that no longer exists —
    /// because the package that declared it was disabled or removed — falls back
    /// to the workbench instead of leaving the window on nothing.
    var view: EditorStudioView {
        let requested = state.requestedView
        if requested == .agent, !availableViews().contains(.agent), let contributed = availableViews().first(where: { $0 != .make }) {
            return contributed
        }
        return availableViews().contains(requested) ? requested : .make
    }

    private let publisher = _ObservablePublisher<EditorAssistantSurface>()

    nonisolated(unsafe) private static var byApplication: [ObjectIdentifier: EditorAssistantSurface] = [:]

    /// One surface per conversation host: a project's editor, or a standalone
    /// session that belongs to no project.
    static func of(_ host: AssistantHosting) -> EditorAssistantSurface {
        let key = ObjectIdentifier(host)
        if let existing = byApplication[key] { return existing }
        let created = EditorAssistantSurface()
        created.availableViews = { [weak host] in host?.studioViews ?? [.make] }
        byApplication[key] = created
        return created
    }

    /// A closed host's object identifier can be reused by the next one.
    static func release(_ host: AssistantHosting) { byApplication[ObjectIdentifier(host)] = nil }

    func show(_ view: EditorStudioView) {
        // Asking for a view no enabled package declares would leave a request
        // that only takes effect if the package comes back; refuse it so the
        // window cannot reopen on a view that does not exist.
        let target = view == .agent ? availableViews().first(where: { $0 != .make }) ?? view : view
        guard availableViews().contains(target) else { return }
        update { $0.requestedView = target }
    }

    func showCanvas(_ canvas: Canvas) { update { $0.canvas = canvas } }

    var regions: State.Regions { state.regions[view] ?? .init() }

    func toggleRegion(leading: Bool) {
        let mode = view
        update {
            var regions = $0.regions[mode] ?? .init()
            if leading { regions.leading.toggle() } else { regions.trailing.toggle() }
            $0.regions[mode] = regions
        }
    }

    func selectRegionPanel(_ id: String, slot: String) {
        let mode = view
        update {
            var regions = $0.regions[mode] ?? .init()
            regions.selectedPanels[slot] = id
            $0.regions[mode] = regions
        }
    }

    /// Called before the bundled packages start registering. Until
    /// `finishLaunch()` the window paints the launch surface rather than an
    /// editor whose views and theme are not known yet.
    func beginLaunch() { update { $0.isReady = false } }

    /// Called once every bundled package has registered its contributions —
    /// or once startup has given up on them.
    func finishLaunch() { update { $0.isReady = true } }

    /// Cycles through whatever views exist, so a third view needs no change here.
    func toggleView() {
        let views = availableViews()
        guard views.count > 1 else { return }
        let index = views.firstIndex(of: view) ?? 0
        show(views[(index + 1) % views.count])
    }

    /// The composer lives in the agent view, so asking brings it to the front.
    func focus() {
        guard availableViews().contains(.agent) else { return }
        update { $0.requestedView = .agent; $0.focusRequest &+= 1 }
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
