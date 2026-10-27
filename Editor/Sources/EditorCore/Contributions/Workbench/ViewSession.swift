import Foundation
import CoveUICompose
import PluginRuntime

/// One plugin view: the state its entry point last returned, the component
/// tree to draw and the values of its controls. Persistent plugin processes
/// keep their own services; view state is also handed back with every event.
/// Events run one at a time, in order; typing only reaches the plugin for
/// fields that ask for `change`, and then debounced.
public final class PluginViewSession: _ObservableObject, @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var ui: UINode?
        public var isBusy = false
        public var failure: String?
    }

    public typealias Invoke = @MainActor (_ state: PluginJSON?, _ event: UIEvent?) async throws -> PluginViewResult

    public let source: PluginContentSource
    public private(set) var snapshot = Snapshot()
    /// The value each field, toggle and select shows, by component ID. Typing
    /// changes it here without calling the plugin; see `adoptValues` for when
    /// the plugin's values replace it.
    public private(set) var values: [String: PluginJSON] = [:]
    private var pluginValues: [String: PluginJSON] = [:]
    private var state: PluginJSON?
    private let invoke: Invoke
    private let uiQueue: PluginUIQueue
    private var tail: Task<Void, Never>?
    /// Calls queued or running; the view is busy until it reaches zero.
    private var pending = 0
    private var pendingChange: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var isCancelled = false
    private var refreshGeneration: UInt64 = 0
    private let publisher = _ObservablePublisher<PluginViewSession>()

    static let changeDelay: Duration = .milliseconds(300)

    init(source: PluginContentSource, invoke: @escaping Invoke, uiQueue: PluginUIQueue = PluginUIQueue()) {
        self.source = source
        self.invoke = invoke
        self.uiQueue = uiQueue
    }

    /// Draws the view again from the current state.
    @MainActor
    public func render() { enqueue(nil) }

    /// Raises a component's action with the current control values.
    @MainActor
    public func send(action: String, arguments: PluginJSON? = nil, value: PluginJSON? = nil) {
        pendingChange?.cancel()
        enqueue(UIEvent(action: action, arguments: arguments, value: value, values: values))
    }

    /// Records a control's new value. With a `change` action, the plugin hears
    /// about it once typing pauses.
    @MainActor
    public func setValue(_ value: PluginJSON, for id: String, change action: String? = nil) {
        guard values[id] != value else { return }
        values[id] = value
        publisher.send()
        guard let action else { return }
        pendingChange?.cancel()
        let event = UIEvent(action: action, value: value, values: values)
        let uiQueue = uiQueue
        pendingChange = Task.detached { [weak self] in
            try? await Task.sleep(for: Self.changeDelay)
            guard !Task.isCancelled else { return }
            uiQueue.schedule { [weak self] in self?.enqueue(event) }
        }
    }

    func cancel() {
        isCancelled = true
        refreshTask?.cancel()
        refreshGeneration &+= 1
        pendingChange?.cancel()
        tail?.cancel()
    }

    @MainActor
    private func enqueue(_ event: UIEvent?) {
        guard !isCancelled else { return }
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let previous = tail
        pending += 1
        publish { $0.isBusy = true }
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { pending -= 1; publish { $0.isBusy = self.pending > 0 } }
            do {
                let result = try await invoke(state, event)
                guard !Task.isCancelled else { return }
                if let next = result.state { state = next }
                adoptValues(from: result.ui, afterEvent: event != nil)
                publish { $0.ui = result.ui; $0.failure = nil }
                effectHandler?(result.effects)
                if let milliseconds = result.refreshAfterMilliseconds {
                    let generation = refreshGeneration
                    let uiQueue = uiQueue
                    refreshTask = Task.detached { [weak self] in
                        try? await Task.sleep(for: .milliseconds(milliseconds))
                        guard !Task.isCancelled else { return }
                        uiQueue.schedule { [weak self] in
                            guard let self, self.refreshGeneration == generation else { return }
                            self.render()
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                publish { $0.failure = error.localizedDescription }
            }
        }
    }

    /// Carries out a result's effects; installed by the workbench.
    var effectHandler: (@MainActor ([UIEffect]) -> Void)?

    /// After an event, every value the plugin returns wins: it answers what the
    /// user just did. On a plain render the user's edits stay unless the plugin
    /// changed its value. A field without a value belongs to the host.
    private func adoptValues(from tree: UINode, afterEvent: Bool) {
        var seen: [String: PluginJSON?] = [:]
        tree.collectValues(into: &seen)
        var next: [String: PluginJSON] = [:]
        for (id, value) in seen {
            if let value, afterEvent || pluginValues[id] != value || values[id] == nil {
                next[id] = value
            } else {
                next[id] = values[id] ?? value ?? .string("")
            }
        }
        pluginValues = seen.compactMapValues { $0 }
        values = next
    }

    private func publish(_ change: (inout Snapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

private extension UINode {
    /// The value each control in the tree carries, by component ID; nil for a
    /// field that leaves its text to the host.
    func collectValues(into values: inout [String: PluginJSON?]) {
        switch kind {
        case let .textField(field): values[field.id] = .some(field.value.map(PluginJSON.string))
        case let .toggle(toggle): values[toggle.id] = .bool(toggle.value)
        case let .select(select): values[select.id] = .string(select.value)
        case let .column(stack), let .row(stack): stack.children.forEach { $0.collectValues(into: &values) }
        case let .scroll(child): child.collectValues(into: &values)
        case let .section(_, children): children.forEach { $0.collectValues(into: &values) }
        case let .disclosure(disclosure): disclosure.children.forEach { $0.collectValues(into: &values) }
        case .spacer, .text, .badge, .icon, .progress, .button, .table: break
        }
    }
}

/// What a ``PluginViewSession`` shows.
public enum PluginContentSource: Sendable, Equatable {
    case panel(ContributedPanel)
    case document(ContributedDocumentView, path: String)

    public var pluginID: String {
        switch self {
        case let .panel(panel): panel.pluginID
        case let .document(view, _): view.pluginID
        }
    }

    var key: String {
        switch self {
        case let .panel(panel): "panel:" + panel.id
        case let .document(view, path): "document:" + view.pluginID + "." + view.id + ":" + path
        }
    }

    /// Whether the catalog still contributes exactly this source.
    func isCurrent(in catalog: WorkbenchCatalog) -> Bool {
        switch self {
        case let .panel(panel): catalog.panel(id: panel.id) == panel
        case let .document(view, _): catalog.documentViews.contains(view)
        }
    }
}
