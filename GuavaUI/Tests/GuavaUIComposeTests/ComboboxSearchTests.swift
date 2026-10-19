import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Remote combobox requests: only the newest query publishes, failures can be
/// retried, and short queries never reach the data layer.
@Suite("Combobox remote search")
struct ComboboxSearchTests {
    private final class WorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [() -> Void] = []
        func enqueue(_ work: @escaping () -> Void) { lock.withLock { items.append(work) } }
        /// Waits until `count` publications arrived, then runs them in order.
        func drain(expecting count: Int = 1) async {
            for _ in 0..<400 where lock.withLock({ items.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
            let work = lock.withLock { defer { items.removeAll() }; return items }
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
        let search = ComboboxSearch<Int>(results: { query in
            calls.record(query)
            if query == "slow" { try await Task.sleep(for: .seconds(5)) }
            return [SelectOption(value: query.count, label: "\(query) result"), SelectOption(value: query.count, label: "duplicate")]
        }) { $0.delay = .zero }
        session.request("slow", search: search, enqueue: queue.enqueue)
        try? await Task.sleep(for: .milliseconds(20))
        session.request("fast", search: search, enqueue: queue.enqueue)
        #expect(session.phase == .loading)
        await queue.drain()
        #expect(session.phase == .loaded)
        #expect(session.results.map(\.label) == ["fast result"], "duplicate values are dropped")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(queue.isEmpty, "the cancelled request never publishes")
        #expect(calls.all == ["slow", "fast"])
        session.request("fast", search: search, enqueue: queue.enqueue)
        #expect(calls.all.count == 2 && session.phase == .loaded, "a loaded query is not requested again")
    }

    @Test("Typing waits for the quiet period; only the last query is requested")
    func debounce() async {
        let queue = WorkQueue(), calls = Calls(), session = ComboboxSearchSession<Int>()
        let search = ComboboxSearch<Int>(results: { calls.record($0); return [] }) { $0.delay = .milliseconds(60) }
        for query in ["p", "pa", "par"] { session.request(query, search: search, enqueue: queue.enqueue) }
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
        try? await Task.sleep(for: .milliseconds(20))
        #expect(queue.isEmpty && calls.all.isEmpty)
        session.request("abc", search: search, enqueue: nil)
        #expect(session.phase == .failed("Search needs a running host"))
        let clamped = ComboboxSearch<Int>(results: { _ in [] }) { $0.minimumQueryLength = -3; $0.delay = .seconds(-1) }
        #expect(clamped.minimumQueryLength == 0 && clamped.delay == .zero)
    }
}
