import Foundation
import GuavaUICompose
import PluginRuntime

/// Content a package describes, for a panel or a document view, as its entry
/// point last described it. The host asks when the view is first built and
/// after each of the package's commands, keeping the last good content while
/// a new one loads.
public final class PluginPanelState: _ObservableObject, @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var model: PanelModel?
        public var isLoading = false
        public var failure: String?
    }

    public let source: PluginContentSource
    public private(set) var snapshot = Snapshot()
    private let publisher = _ObservablePublisher<PluginPanelState>()
    private let describe: @MainActor () async throws -> PanelModel
    private var loading: Task<Void, Never>?

    init(source: PluginContentSource, describe: @escaping @MainActor () async throws -> PanelModel) {
        self.source = source
        self.describe = describe
    }

    /// Asks the plugin again. A request in flight is superseded.
    @MainActor
    public func refresh() {
        loading?.cancel()
        publish { $0.isLoading = true }
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let model = try await describe()
                guard !Task.isCancelled else { return }
                publish { $0 = Snapshot(model: model) }
            } catch {
                guard !Task.isCancelled else { return }
                publish { $0.isLoading = false; $0.failure = error.localizedDescription }
            }
        }
    }

    func cancel() { loading?.cancel() }

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

/// What a ``PluginPanelState`` describes.
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
