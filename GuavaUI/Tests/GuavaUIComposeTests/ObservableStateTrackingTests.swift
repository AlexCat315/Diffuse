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

    @Test("Independent keys only recompose their readers")
    func independentKeysRecomposeOnlyReadingScopes() { GlobalTestLock.locked {
        let store = TestObservableStore()
        let valueCounter = BodyCounter()
        let otherCounter = BodyCounter()
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)

        graph.install(root: TwoObservedValuesView(store: store,
                                                  valueCounter: valueCounter,
                                                  otherCounter: otherCounter))
        #expect(valueCounter.count == 1)
        #expect(otherCounter.count == 1)

        store.value = 1
        recomposer.commitAll()

        #expect(valueCounter.count == 2)
        #expect(otherCounter.count == 1)
    } }

    @Test("Observed dynamic properties do not accumulate observers across parent rebuilds")
    func observedDynamicPropertyDoesNotAccumulateObserversAcrossParentRebuilds() { GlobalTestLock.locked {
        let object = CountingObservableObject()
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let root = ObservedRebuildHarness(object: object)

        graph.install(root: root)
        #expect(object.observerCount == 1)

        for _ in 0..<10 {
            root.$tick.wrappedValue += 1
            while recomposer.commitAll() {}
            #expect(object.observerCount == 1)
        }
    } }

    @Test("Observed dynamic properties unregister when removed from the tree")
    func observedDynamicPropertyUnregistersWhenRemovedFromTree() { GlobalTestLock.locked {
        let object = CountingObservableObject()
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let root = ConditionalObservedHarness(object: object)

        graph.install(root: root)
        #expect(object.observerCount == 1)

        root.$isVisible.wrappedValue = false
        while recomposer.commitAll() {}
        #expect(object.observerCount == 0)

        root.$isVisible.wrappedValue = true
        while recomposer.commitAll() {}
        #expect(object.observerCount == 1)
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
        case otherValue
        case shouldRead
    }

    private let registrar = ObservableStateRegistrar()
    private var storedValue = 0
    private var storedOtherValue = 0
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

    var otherValue: Int {
        get {
            registrar.access(AnyHashable(Key.otherValue))
            return storedOtherValue
        }
        set {
            storedOtherValue = newValue
            registrar.invalidate(AnyHashable(Key.otherValue))
        }
    }
}

private final class CountingObservableObject: _ObservableObject {
    private var observers: [AnyHashable: () -> Void] = [:]
    private var nextToken: UInt64 = 0

    var value = 0 {
        didSet {
            for observer in observers.values {
                observer()
            }
        }
    }

    var observerCount: Int {
        observers.count
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        let token = AnyHashable(nextToken)
        nextToken &+= 1
        observers[token] = handler
        return token
    }

    func _unregisterObserver(_ token: AnyHashable) {
        observers.removeValue(forKey: token)
    }
}

private struct ObservedRebuildHarness: View {
    @State var tick = 0
    let object: CountingObservableObject

    var body: some View {
        let _ = tick
        ObservedObjectLeaf(object: object)
    }
}

private struct ConditionalObservedHarness: View {
    @State var isVisible = true
    let object: CountingObservableObject

    var body: some View {
        if isVisible {
            ObservedObjectLeaf(object: object)
        } else {
            Text("hidden")
        }
    }
}

private struct ObservedObjectLeaf: View {
    private var _value: Observed<CountingObservableObject, Int>
    private var value: Int { _value.wrappedValue }

    init(object: CountingObservableObject) {
        self._value = Observed(\.value, on: object)
    }

    var body: some View {
        Text("value \(value)")
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

private struct TwoObservedValuesView: View {
    let store: TestObservableStore
    let valueCounter: BodyCounter
    let otherCounter: BodyCounter

    var body: some View {
        Row {
            ObservedValueView(store: store, counter: valueCounter)
            ObservedOtherValueView(store: store, counter: otherCounter)
        }
    }
}

private struct ObservedOtherValueView: View {
    let store: TestObservableStore
    let counter: BodyCounter

    var body: some View {
        let _ = counter.bump()
        Text("other \(store.otherValue)")
    }
}
