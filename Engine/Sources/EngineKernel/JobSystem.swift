import Foundation

public struct JobDispatchReport: Sendable, Equatable {
    public var jobCount: Int
    public var workerCount: Int
    public var executedInParallel: Bool

    public init(jobCount: Int = 0, workerCount: Int = 1, executedInParallel: Bool = false) {
        self.jobCount = jobCount
        self.workerCount = workerCount
        self.executedInParallel = executedInParallel
    }
}

public final class JobSystem: @unchecked Sendable {
    public static let shared = JobSystem()

    public let workerCount: Int
    public let minimumChunkSize: Int

    private let queue: DispatchQueue

    public init(
        workerCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        minimumChunkSize: Int = 64,
        label: String = "com.guava.engine.jobs"
    ) {
        self.workerCount = max(workerCount, 1)
        self.minimumChunkSize = max(minimumChunkSize, 1)
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
    }

    @discardableResult
    public func parallelFor(
        count: Int,
        minimumChunkSize: Int? = nil,
        _ body: @escaping @Sendable (Range<Int>) -> Void
    ) -> JobDispatchReport {
        let chunks = chunkRanges(count: count, minimumChunkSize: minimumChunkSize)
        guard !chunks.isEmpty else {
            return JobDispatchReport(jobCount: 0, workerCount: workerCount, executedInParallel: false)
        }
        if chunks.count == 1 {
            body(chunks[0])
            return JobDispatchReport(jobCount: 1, workerCount: workerCount, executedInParallel: false)
        }

        let group = DispatchGroup()
        for range in chunks {
            group.enter()
            queue.async {
                body(range)
                group.leave()
            }
        }
        group.wait()
        return JobDispatchReport(jobCount: chunks.count, workerCount: workerCount, executedInParallel: true)
    }

    public func parallelCompactMap<Input: Sendable, Output: Sendable>(
        items: [Input],
        minimumChunkSize: Int? = nil,
        _ transform: @escaping @Sendable (Input) -> Output?
    ) -> ([Output], JobDispatchReport) {
        let chunks = chunkRanges(count: items.count, minimumChunkSize: minimumChunkSize)
        guard !chunks.isEmpty else {
            return ([], JobDispatchReport(jobCount: 0, workerCount: workerCount, executedInParallel: false))
        }
        if chunks.count == 1 {
            return (
                chunks[0].compactMap { index in transform(items[index]) },
                JobDispatchReport(jobCount: 1, workerCount: workerCount, executedInParallel: false)
            )
        }

        let chunkResults = ChunkResultsBox<Output>(count: chunks.count)
        let group = DispatchGroup()

        for (chunkIndex, range) in chunks.enumerated() {
            group.enter()
            queue.async {
                let output = range.compactMap { index in transform(items[index]) }
                chunkResults.set(output, at: chunkIndex)
                group.leave()
            }
        }
        group.wait()

        return (
            chunkResults.snapshot().flatMap { $0 },
            JobDispatchReport(jobCount: chunks.count, workerCount: workerCount, executedInParallel: true)
        )
    }

    private func chunkRanges(count: Int, minimumChunkSize: Int?) -> [Range<Int>] {
        guard count > 0 else { return [] }

        let resolvedMinimumChunkSize = max(minimumChunkSize ?? self.minimumChunkSize, 1)
        if workerCount <= 1 || count <= resolvedMinimumChunkSize {
            return [0..<count]
        }

        let targetChunkCount = min(
            workerCount,
            max(1, (count + resolvedMinimumChunkSize - 1) / resolvedMinimumChunkSize)
        )
        let chunkSize = max(resolvedMinimumChunkSize, (count + targetChunkCount - 1) / targetChunkCount)

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(targetChunkCount)
        var start = 0
        while start < count {
            let end = min(start + chunkSize, count)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

private final class ChunkResultsBox<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Output]]

    init(count: Int) {
        self.values = Array(repeating: [], count: count)
    }

    func set(_ value: [Output], at index: Int) {
        lock.withLock {
            values[index] = value
        }
    }

    func snapshot() -> [[Output]] {
        lock.withLock { values }
    }
}
