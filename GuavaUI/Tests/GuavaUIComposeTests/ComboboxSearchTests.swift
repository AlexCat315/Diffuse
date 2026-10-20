import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Remote combobox requests: only the newest query publishes, failures can be
/// retried, and short queries never reach the data layer. Every wait is on an
/// event the session produces, never on elapsed time; the time limit only
/// turns a regression into a failure instead of a hang.
@Suite("Combobox remote search", .timeLimit(.minutes(1)))
struct ComboboxSearchTests {
    /// Counts events and lets a test await a running total.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        func record() {
            let ready = lock.withLock {
                count += 1
                defer { waiters.removeAll { $0.target <= count } }
                return waiters.filter { $0.target <= count }
            }
            ready.forEach { $0.continuation.resume() }
        }
        func wait(for target: Int) async {
            await withCheckedContinuation { continuation in
                let reached = lock.withLock {
                    if count >= target { return true }
                    waiters.append((target, continuation)); return false
                }
                if reached { continuation.resume() }
            }
        }
    }
    private final class WorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [() -> Void] = []
        private var drained = 0
        private let arrivals = Events()
        func enqueue(_ work: @escaping () -> Void) { lock.withLock { items.append(work) }; arrivals.record() }
        /// Waits until `count` more publications arrived, then runs them in order.
        func drain(expecting count: Int = 1) async {
            await arrivals.wait(for: lock.withLock { drained + count })
            let work = lock.withLock { defer { drained += items.count; items.removeAll() }; return items }
            work.forEach { $0() }
        }
        var isEmpty: Bool { lock.withLock { items.isEmpty } }
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ query: String) { lock.withLock { values.append(query) } }
        var all: [String] { lock.withLock { values } }
    }
    private struct Offline: LocalizedError { var errorDescription: String? { "Offline" } }


    @Test("A superseded request is cancelled and cannot publish over the newer query")
    func supersede() async {
        let queue = WorkQueue(), calls = Calls(), session = ComboboxSearchSession<Int>()
        let slowStarted = Events(), slowEnded = Events()
        let search = ComboboxSearch<Int>(results: { query in
            calls.record(query)
            if query == "slow" {
                defer { slowEnded.record() }
                slowStarted.record()
                try await Task.sleep(for: .seconds(3600))
            }
            return [SelectOption(value: query.count, label: "\(query) result"), SelectOption(value: query.count, label: "duplicate")]
        }) { $0.delay = .zero }
        session.request("slow", search: search, enqueue: queue.enqueue)
        await slowStarted.wait(for: 1)
        session.request("fast", search: search, enqueue: queue.enqueue)
        #expect(session.phase == .loading)
        await queue.drain()
        #expect(session.phase == .loaded)
        #expect(session.results.map(\.label) == ["fast result"], "duplicate values are dropped")
        await slowEnded.wait(for: 1)
        #expect(queue.isEmpty, "the cancelled request never publishes")
        #expect(calls.all == ["slow", "fast"])
        session.request("fast", search: search, enqueue: queue.enqueue)
        #expect(calls.all.count == 2 && session.phase == .loaded, "a loaded query is not requested again")
    }

    @Test("Typing waits for the quiet period; only the last query is requested")
    func debounce() async {
        let queue = WorkQueue(), calls = Calls(), session = ComboboxSearchSession<Int>()
        let typing = ComboboxSearch<Int>(results: { calls.record($0); return [] }) { $0.delay = .seconds(3600) }
        let settled = ComboboxSearch<Int>(results: typing.results) { $0.delay = .milliseconds(1) }
        for query in ["p", "pa"] { session.request(query, search: typing, enqueue: queue.enqueue) }
        session.request("par", search: settled, enqueue: queue.enqueue)
        await queue.drain()
        #expect(calls.all == ["par"])
        #expect(session.phase == .loaded && session.results.isEmpty)
    }

    @Test("Failures surface their message and a forced retry requests again")
    func failureAndRetry() async {
        let queue = WorkQueue(), calls = Calls(), session = ComboboxSearchSession<Int>()
        let search = ComboboxSearch<Int>(results: { query in
            calls.record(query)
            if calls.all.count == 1 { throw Offline() }
            return [SelectOption(value: 1, label: "Paris")]
        }) { $0.delay = .zero }
        session.request("pa", search: search, enqueue: queue.enqueue)
        await queue.drain()
        #expect(session.phase == .failed("Offline"))
        session.request("pa", search: search, immediately: true, force: true, enqueue: queue.enqueue)
        await queue.drain()
        #expect(session.phase == .loaded && session.results.map(\.label) == ["Paris"])
    }

    @Test("Short queries prompt without requesting; cancel returns a pending request to idle; no host fails visibly")
    func boundaries() async {
        let queue = WorkQueue(), calls = Calls(), session = ComboboxSearchSession<Int>()
        let search = ComboboxSearch<Int>(results: { calls.record($0); return [] }) { $0.minimumQueryLength = 2; $0.delay = .seconds(5) }
        session.request(" a ", search: search, enqueue: queue.enqueue)
        #expect(session.phase == .tooShort(2) && calls.all.isEmpty)
        session.request("abc", search: search, enqueue: queue.enqueue)
        #expect(session.phase == .loading)
        session.cancel()
        #expect(session.phase == .idle)
        #expect(queue.isEmpty && calls.all.isEmpty)
        session.request("abc", search: search, enqueue: nil)
        #expect(session.phase == .failed("Search needs a running host"))
        let clamped = ComboboxSearch<Int>(results: { _ in [] }) { $0.minimumQueryLength = -3; $0.delay = .seconds(-1) }
        #expect(clamped.minimumQueryLength == 0 && clamped.delay == .zero)
    }
}
