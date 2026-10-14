import GuavaLogCore

/// Fixed storage prevents per-record shifts when the replay window is full.
struct LogHistory {
    private var storage: [LogRecord?]
    private var next = 0
    private(set) var count = 0
    init(capacity: Int) { storage = Array(repeating: nil, count: capacity) }
    var records: [LogRecord] {
        guard count > 0 else { return [] }
        let start = count == storage.count ? next : 0
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }
    mutating func append(_ record: LogRecord) {
        guard !storage.isEmpty else { return }
        storage[next] = record; next = (next + 1) % storage.count; count = min(count + 1, storage.count)
    }
    mutating func resize(_ capacity: Int) {
        guard capacity != storage.count else { return }
        let retained = records.suffix(capacity)
        self = LogHistory(capacity: capacity)
        for record in retained { append(record) }
    }
    mutating func identifyStartup(_ process: LogRecord.Process) {
        for index in storage.indices { storage[index]?.process = process }
    }
}
