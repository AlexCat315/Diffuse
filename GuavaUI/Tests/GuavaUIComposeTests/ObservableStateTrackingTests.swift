import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Observable state tracking", .serialized)
struct ObservableStateTrackingTests: GuavaUIComposeSerializedSuite {
    @Test("State reads during body evaluation recompose automatically")
    func stateReadInvalidatesOwningScope() { GlobalTestLock.locked {
        let store = TestObservableStore()
        let counter = BodyCounter()
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)

        graph.install(root: ObservedValueView(store: store, counter: counter))
        #expect(counter.count == 1)
        #expect(recomposer.hasPending == false)

        store.value = 1
        #expect(recomposer.hasPending == true)

        recomposer.commitAll()
        #expect(counter.count == 2)
        #expect(recomposer.hasPending == false)
    } }

    @Test("Dependencies are replaced on each body evaluation")
    func dependenciesAreClearedWhenBodyStopsReading() { GlobalTestLock.locked {
        let store = TestObservableStore()
        let counter = BodyCounter()
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)

        graph.install(root: ConditionalObservedValueView(store: store, counter: counter))
        #expect(counter.count == 1)

        store.value = 1
        recomposer.commitAll()
        #expect(counter.count == 2)

        store.shouldRead = false
        recomposer.commitAll()
        #expect(counter.count == 3)

        store.value = 2
        #expect(recomposer.hasPending == false)
        #expect(counter.count == 3)
    } }
}

private final class BodyCounter {
    var count = 0

    func bump() {
        count += 1
    }
}

private final class TestObservableStore {
    private enum Key: Hashable {
        case value
        case shouldRead
    }

    private let registrar = ObservableStateRegistrar()
    private var storedValue = 0
    private var storedShouldRead = true

    var value: Int {
        get {
            registrar.access(AnyHashable(Key.value))
            return storedValue
        }
        set {
            storedValue = newValue
            registrar.invalidate(AnyHashable(Key.value))
        }
    }

    var shouldRead: Bool {
        get {
            registrar.access(AnyHashable(Key.shouldRead))
            return storedShouldRead
        }
        set {
            storedShouldRead = newValue
            registrar.invalidate(AnyHashable(Key.shouldRead))
        }
    }
}

private struct ObservedValueView: View {
    let store: TestObservableStore
    let counter: BodyCounter

    var body: some View {
        let _ = counter.bump()
        Text("value \(store.value)")
    }
}

private struct ConditionalObservedValueView: View {
    let store: TestObservableStore
    let counter: BodyCounter

    var body: some View {
        let _ = counter.bump()
        if store.shouldRead {
            Text("value \(store.value)")
        } else {
            Text("idle")
        }
    }
}
