import Foundation
import GuavaUIRuntime

public struct DataTableSortingStatus: Equatable, Sendable {
    public internal(set) var isPending = false
    public internal(set) var completedBuilds = 0
    public internal(set) var cacheHits = 0
    public internal(set) var lastDuration: Double = 0
    public init() {}
}

/// UI-owned row storage and a persistent display projection. Rendering reads
/// rows and ID positions in O(1); sorting and its ID index are built on a serial
/// worker, once per command. Keep this model in application state, not in body.
public final class DataTableModel<Record: Sendable, ID: Hashable & Sendable>: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<DataTableModel>()
    private let worker = DataTableSortWorker<Record, ID>()
    private var storage: DataTableStorage<Record, ID>
    private var projection: DataTableProjection<ID>?
    private var cache: [DataTableCachedSort<ID>] = []
    private var generation: UInt64 = 0
    private var comparator: (@Sendable (Record, Record) -> ComparisonResult)?
    public private(set) var sort: TableSort?
    public private(set) var sorting = DataTableSortingStatus()
    public private(set) var revision: UInt64 = 0

    public init(_ records: [Record], id: KeyPath<Record, ID>) { storage = DataTableStorage(records, id: id) }
    public var count: Int { storage.records.count }
    public func record(at index: Int) -> Record {
        precondition(index >= 0 && index < count)
        return storage.records[projection?.order[index] ?? index]
    }
    public func rowID(at index: Int) -> ID {
        precondition(index >= 0 && index < count)
        return storage.ids[projection?.order[index] ?? index]
    }
    public func index(for id: ID) -> Int? { projection?.positions[id] ?? storage.positions[id] }
    public func record(for id: ID) -> Record? { storage.positions[id].map { storage.records[$0] } }

    /// Replacement validates IDs once and resets the display projection. An
    /// active sort is reapplied; its old async reply cannot affect the new rows.
    public func replaceRows(_ records: [Record]) {
        storage = DataTableStorage(records, id: storage.id); projection = nil; cache = []
        generation &+= 1
        if let sort, let comparator { schedule(sort, compare: comparator) }
        else { sorting.isPending = false; publish() }
    }
    /// Mutating one row keeps its stable identity. Authored data changes here;
    /// selection, viewport and edit drafts belong to the table's session.
    @discardableResult
    public func updateRow(_ id: ID, _ update: (inout Record) -> Void) -> Bool {
        guard let index = storage.positions[id] else { return false }
        var record = storage.records[index]; update(&record)
        precondition(record[keyPath: storage.id] == id, "Editing a row must preserve its ID")
        storage.records[index] = record; cache = []; generation &+= 1
        if let sort, let comparator { schedule(sort, compare: comparator) }
        else { publish() }
        return true
    }
    public func setSort(_ next: TableSort?, compare: (@Sendable (Record, Record) -> ComparisonResult)? = nil) {
        guard next != sort else { return }
        generation &+= 1; sort = next; comparator = compare
        guard let next, let compare else { projection = nil; sorting.isPending = false; publish(); return }
        if let cached = cache.first(where: { $0.sort == next }) {
            projection = cached.projection; sorting.cacheHits += 1; sorting.isPending = false; publish()
        } else { schedule(next, compare: compare) }
    }
    private func schedule(_ sort: TableSort, compare: @escaping @Sendable (Record, Record) -> ComparisonResult) {
        sorting.isPending = true; publish()
        let token = generation
        worker.request(DataTableSortRequest(records: storage.records, ids: storage.ids, sort: sort, compare: compare)) { [weak self] result, duration in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.sort == sort else { return }
                self.projection = result
                self.cache.removeAll { $0.sort == sort }
                self.cache.append(DataTableCachedSort(sort: sort, projection: result))
                if self.cache.count > 2 { self.cache.removeFirst() }
                self.sorting.isPending = false; self.sorting.completedBuilds += 1; self.sorting.lastDuration = duration
                self.publish()
            }
        }
    }
    private func publish() { revision &+= 1; publisher.send() }
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

private struct DataTableStorage<Record, ID: Hashable> {
    var records: [Record]
    let id: KeyPath<Record, ID>
    let ids: [ID]
    let positions: [ID: Int]
    init(_ records: [Record], id: KeyPath<Record, ID>) {
        self.records = records; self.id = id
        ids = records.map { $0[keyPath: id] }
        var positions: [ID: Int] = [:]; positions.reserveCapacity(records.count)
        for (index, value) in ids.enumerated() {
            precondition(positions.updateValue(index, forKey: value) == nil, "DataTable row IDs must be unique")
        }
        self.positions = positions
    }
}
struct DataTableProjection<ID: Hashable & Sendable>: Sendable {
    let order: [Int]
    let positions: [ID: Int]
}
private struct DataTableCachedSort<ID: Hashable & Sendable> {
    let sort: TableSort
    let projection: DataTableProjection<ID>
}
