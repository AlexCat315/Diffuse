import GuavaLogCore

struct UnifiedLogHandler: LogHandler {
    let label: String
    let runtime: LogRuntime
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider? = nil
    private var localLevel: Logger.Level? = nil
    var logLevel: Logger.Level {
        get { localLevel ?? runtime.minimum(for: label) }
        set { localLevel = newValue }
    }
    init(label: String, runtime: LogRuntime) { self.label = label; self.runtime = runtime }
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        var values = LogContext.metadata
        if let provider = metadataProvider { values.merge(provider.get()) { _, new in new } }
        values.merge(metadata) { _, new in new }
        if let explicit = event.metadata { values.merge(explicit) { _, new in new } }
        runtime.submit(label: label, event: event, metadata: values)
    }
}
