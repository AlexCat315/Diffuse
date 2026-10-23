import CapabilityRuntime

/// Transient authority and drafts belong together and never enter chat history.
struct SessionCapabilityState: Sendable {
    private let hostRegistry: CapabilityRegistry
    var registry: CapabilityRegistry
    var drafts: CapabilityDraftStore
    var executor: PluginCapabilityExecutor?
    var querySnapshotProvider: PluginQuerySnapshotProvider?
    var generation: UInt64 = 0
    var submittedSnapshot: CapabilityExposureSnapshot?
    var submittedDrafts: [CapabilityInvocationDraft] = []

    init(hostRegistry: CapabilityRegistry, executor: PluginCapabilityExecutor?,
         querySnapshotProvider: PluginQuerySnapshotProvider?) {
        self.hostRegistry = hostRegistry
        self.executor = executor
        self.querySnapshotProvider = querySnapshotProvider
        registry = executor?.registry ?? hostRegistry
        drafts = CapabilityDraftStore(registry: registry)
    }

    mutating func replace(_ executor: PluginCapabilityExecutor?, querySnapshotProvider: PluginQuerySnapshotProvider?) {
        self.executor = executor
        self.querySnapshotProvider = querySnapshotProvider
        registry = executor?.registry ?? hostRegistry
        drafts = CapabilityDraftStore(registry: registry)
        generation &+= 1
        submittedSnapshot = nil
        submittedDrafts = []
    }
}
