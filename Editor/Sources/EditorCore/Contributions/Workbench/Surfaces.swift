import Foundation
import GuavaUICompose
import PluginRuntime

/// The workbench domain of one editor session: its catalog, the content
/// packages describe for it and the shell to tell when it changes. Views
/// observe `catalog` to follow packages as they come and go.
public final class WorkbenchSession: _ObservableObject, @unchecked Sendable {
    public private(set) var catalog = WorkbenchCatalog.empty
    private let publisher = _ObservablePublisher<WorkbenchSession>()
    private var revisions: [UInt64] = []
    private var states: [String: PluginPanelState] = [:]
    var onChange: (@MainActor () -> Void)?

    /// Publishes a new catalog when the registrations behind it changed.
    @MainActor
    func update(_ snapshots: [ContributionSnapshot<ValidatedPluginPackage>]) {
        let next = snapshots.map(\.revision)
        guard next != revisions else { return }
        revisions = next
        var packages: [String: ValidatedPluginPackage] = [:]
        for value in snapshots.flatMap(\.values) { packages[value.pluginID] = value.value }
        replace(WorkbenchCatalog(packages: Array(packages.values)))
    }

    /// Content loaded for a panel or view that left or changed is dropped with it.
    @MainActor
    func replace(_ catalog: WorkbenchCatalog) {
        guard catalog != self.catalog else { return }
        self.catalog = catalog
        for (key, state) in states where !state.source.isCurrent(in: catalog) {
            state.cancel()
            states.removeValue(forKey: key)
        }
        publisher.send()
        onChange?()
    }

    @MainActor
    func state(for source: PluginContentSource,
               describe: @escaping @MainActor () async throws -> PanelModel) -> PluginPanelState {
        if let state = states[source.key], state.source == source { return state }
        let state = PluginPanelState(source: source, describe: describe)
        states[source.key] = state
        state.refresh()
        return state
    }

    /// A command may change what the package's panels and views show.
    @MainActor
    func refreshContent(of pluginID: String) {
        for state in states.values where state.source.pluginID == pluginID { state.refresh() }
    }
}

extension WorkbenchSession {
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
