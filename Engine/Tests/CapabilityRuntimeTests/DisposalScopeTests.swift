import CapabilityRuntime
import Foundation
import Testing

@Suite("Disposal scope")
struct DisposalScopeTests {
    private actor Barrier {
        private var started = false
        private var finished = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !finished { await withCheckedContinuation { finishWaiters.append($0) } }
        }
        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiters.append($0) } }
        }
        func release() {
            finished = true
            finishWaiters.forEach { $0.resume() }
            finishWaiters.removeAll()
        }
    }
    /// Records teardown order across concurrent callers.
    private actor OrderLog {
        private var entries: [Int] = []
        func record(_ value: Int) { entries.append(value) }
        func values() -> [Int] { entries }
    }

    @Test("disposeAll unwinds registrations in reverse order")
    func reverseOrder() async {
        let log = OrderLog()
        let scope = DisposalScope()
        for index in 1...3 {
            scope.track { await log.record(index) }
        }
        await scope.disposeAll()
        let values = await log.values()
        #expect(values == [3, 2, 1])
    }

    @Test("a registration disposes exactly once across early disposal and scope unwind")
    func disposesExactlyOnce() async {
        let log = OrderLog()
        let scope = DisposalScope()
        let first = scope.track { await log.record(1) }
        scope.track { await log.record(2) }

        await first.dispose()
        await first.dispose()
        await scope.disposeAll()
        await scope.disposeAll()

        let values = await log.values()
        #expect(values == [1, 2])
    }

    @Test("scope stays usable after unwinding and accepts transferred handles")
    func reusableAndTransfersHandles() async {
        let log = OrderLog()
        let scope = DisposalScope()
        await scope.disposeAll()

        let borrowed = Registration { await log.record(7) }
        scope.track(borrowed)
        await scope.disposeAll()

        let values = await log.values()
        #expect(values == [7])
    }

    @Test("concurrent tracking never loses a registration")
    func concurrentTracking() async {
        let log = OrderLog()
        let scope = DisposalScope()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    scope.track { await log.record(index) }
                }
            }
        }
        await scope.disposeAll()
        let values = await log.values()
        #expect(values.count == 64)
        #expect(Set(values) == Set(0..<64))
    }

    @Test("tracking after an unwind belongs to the next generation")
    func trackingAfterUnwindIsNotDisposedByEarlierCall() async {
        let log = OrderLog()
        let scope = DisposalScope()
        scope.track { await log.record(1) }
        await scope.disposeAll()

        scope.track { await log.record(2) }
        let afterUnwind = await log.values()
        #expect(afterUnwind == [1])

        await scope.disposeAll()
        let values = await log.values()
        #expect(values == [1, 2])
    }

    @Test("concurrent disposal waits for teardown and serializes generations")
    func concurrentDisposalWaitsForCompletion() async {
        let barrier = Barrier()
        let log = OrderLog()
        let scope = DisposalScope()
        let registration = scope.track {
            await barrier.hold()
            await log.record(1)
        }
        let first = Task { await scope.disposeAll() }
        await barrier.waitUntilStarted()
        let second = Task {
            await registration.dispose()
            await log.record(2)
        }
        scope.track { await log.record(3) }
        let nextGeneration = Task { await scope.disposeAll() }
        await barrier.release()
        await first.value
        await second.value
        await nextGeneration.value
        let values = await log.values()
        #expect(values.first == 1)
        #expect(Set(values) == [1, 2, 3])
    }
}
