import Foundation

struct DataTableSortRequest<Record: Sendable, ID: Hashable & Sendable>: Sendable {
    let records: [Record]
    let ids: [ID]
    let sort: TableSort
    let compare: @Sendable (Record, Record) -> ComparisonResult
    func build() -> DataTableProjection<ID> {
        let direction: ComparisonResult = sort.direction == .ascending ? .orderedAscending : .orderedDescending
        let order = records.indices.sorted { left, right in
            let result = compare(records[left], records[right])
            return result == .orderedSame ? left < right : result == direction
        }
        var positions: [ID: Int] = [:]; positions.reserveCapacity(ids.count)
        for (index, source) in order.enumerated() { positions[ids[source]] = index }
        return DataTableProjection(order: order, positions: positions)
    }
}
/// Only the mailbox is shared. Completed projections are immutable, and the
/// model rejects delivery after a newer row revision or sort command.
final class DataTableSortWorker<Record: Sendable, ID: Hashable & Sendable>: @unchecked Sendable {
    private struct Job: Sendable {
        let request: DataTableSortRequest<Record, ID>
        let deliver: @Sendable (DataTableProjection<ID>, Double) -> Void
    }
    private let queue = DispatchQueue(label: "guava.data-table-sort", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Job?
    private var scheduled = false
    func request(_ request: DataTableSortRequest<Record, ID>, deliver: @escaping @Sendable (DataTableProjection<ID>, Double) -> Void) {
        lock.lock(); pending = Job(request: request, deliver: deliver)
        let start = !scheduled; scheduled = true; lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock(); let job = pending; pending = nil
                if job == nil { scheduled = false }
                lock.unlock()
                guard let job else { return }
                let start = Date.timeIntervalSinceReferenceDate, result = job.request.build()
                job.deliver(result, Date.timeIntervalSinceReferenceDate - start)
            }
        }
    }
}
