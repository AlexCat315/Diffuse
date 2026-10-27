import Foundation
import CoveUICompose
import PluginRuntime

/// The workbench domain of one editor session: its catalog, the content
/// packages describe for it and the shell to tell when it changes. Views
/// observe `catalog` to follow packages as they come and go.
public final class WorkbenchSession: _ObservableObject, @unchecked Sendable {
    let uiQueue = PluginUIQueue()
    public private(set) var catalog = WorkbenchCatalog.empty
    private let publisher = _ObservablePublisher<WorkbenchSession>()
    private var revisions: [UInt64] = []
    private var sessions: [String: PluginViewSession] = [:]
    var onChange: (@MainActor () -> Void)?
    /// Shows a plugin's message; `true` marks a failure. Installed by the shell.
    var notify: (@MainActor (_ text: String, _ isError: Bool) -> Void)?

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
        for (key, session) in sessions where !session.source.isCurrent(in: catalog) {
            session.cancel()
            sessions.removeValue(forKey: key)
        }
        publisher.send()
        onChange?()
    }

    /// The session for a view, created and first rendered on demand.
    @MainActor
    func session(for source: PluginContentSource, invoke: @escaping PluginViewSession.Invoke,
                 effects: @escaping @MainActor ([UIEffect]) -> Void) -> PluginViewSession {
        if let session = sessions[source.key], session.source == source { return session }
        let session = PluginViewSession(source: source, invoke: invoke, uiQueue: uiQueue)
        session.effectHandler = effects
        sessions[source.key] = session
        session.render()
        return session
    }

    /// A command may change what the package's views show.
    @MainActor
    func renderViews(of pluginID: String) {
        for session in sessions.values where session.source.pluginID == pluginID { session.render() }
    }

    func stop() {
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
    }
}

extension WorkbenchSession {
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
