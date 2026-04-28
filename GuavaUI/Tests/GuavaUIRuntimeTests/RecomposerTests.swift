import Testing
@testable import GuavaUIRuntime

@Suite("Recomposer")
struct RecomposerTests {

    @Test("commitAll executes closures in registration order")
    func commitOrder() {
        let r = Recomposer()
        var log: [Int] = []
        // Keep strong references so ARC doesn't reuse the same address for both nodes.
        let n1 = Node(), n2 = Node()
        let id1 = ObjectIdentifier(n1)
        let id2 = ObjectIdentifier(n2)

        r.invalidate(scopeID: id1) { log.append(1) }
        r.invalidate(scopeID: id2) { log.append(2) }
        r.commitAll()

        #expect(log == [1, 2])
        _ = (n1, n2)   // extend lifetime past commitAll
    }

    @Test("duplicate scopeID is dropped within the same frame")
    func deduplication() {
        let r = Recomposer()
        var callCount = 0
        let n = Node()
        let id = ObjectIdentifier(n)

        r.invalidate(scopeID: id) { callCount += 1 }
        r.invalidate(scopeID: id) { callCount += 1 }   // same ID — ignored
        r.commitAll()

        #expect(callCount == 1)
        _ = n
    }

    @Test("commitAll clears the queue")
    func commitClears() {
        let r = Recomposer()
        let n = Node()
        let id = ObjectIdentifier(n)

        r.invalidate(scopeID: id) {}
        #expect(r.hasPending == true)
        r.commitAll()
        #expect(r.hasPending == false)
        _ = n
    }

    @Test("commitAll drains child invalidations queued by parent recomposes")
    func commitDrainsNestedInvalidations() {
        let r = Recomposer()
        var log: [Int] = []
        let parent = Node(), child = Node()
        let parentID = ObjectIdentifier(parent)
        let childID = ObjectIdentifier(child)

        r.invalidate(scopeID: parentID) {
            log.append(1)
            r.invalidate(scopeID: childID) {
                log.append(2)
            }
        }
        r.commitAll()

        #expect(log == [1, 2])
        #expect(r.hasPending == false)
        _ = (parent, child)
    }

    @Test("commitAll leaves self-invalidations queued for the next frame")
    func commitDefersSelfInvalidation() {
        let r = Recomposer()
        var callCount = 0
        let node = Node()
        let id = ObjectIdentifier(node)

        r.invalidate(scopeID: id) {
            callCount += 1
            r.invalidate(scopeID: id) {
                callCount += 1
            }
        }
        r.commitAll()

        #expect(callCount == 1)
        #expect(r.hasPending == true)

        r.commitAll()
        #expect(callCount == 2)
        #expect(r.hasPending == false)
        _ = node
    }

    @Test("commitAll does not retain duplicate invalidations for scopes already queued")
    func commitDropsDuplicateForAlreadyQueuedChild() {
        let r = Recomposer()
        var log: [Int] = []
        let parent = Node(), child = Node()
        let parentID = ObjectIdentifier(parent)
        let childID = ObjectIdentifier(child)

        r.invalidate(scopeID: parentID) {
            log.append(1)
            r.invalidate(scopeID: childID) {
                log.append(3)
            }
        }
        r.invalidate(scopeID: childID) {
            log.append(2)
        }
        r.commitAll()

        #expect(log == [1, 2])
        #expect(r.hasPending == false)
        _ = (parent, child)
    }

    @Test("same scopeID is accepted again in the next frame")
    func scopeReusableAcrossFrames() {
        let r = Recomposer()
        var callCount = 0
        let n = Node()
        let id = ObjectIdentifier(n)

        r.invalidate(scopeID: id) { callCount += 1 }
        r.commitAll()                                  // frame 1

        r.invalidate(scopeID: id) { callCount += 1 }
        r.commitAll()                                  // frame 2

        #expect(callCount == 2)
        _ = n
    }

    @Test("State change wires into Recomposer")
    func stateWiresRecomposer() {
        let r = Recomposer()
        var state = State(wrappedValue: 0)
        var recomposeCount = 0

        let id = ObjectIdentifier(state._storage)
        state._storage.onChange = {
            r.invalidate(scopeID: id) { recomposeCount += 1 }
        }

        state.wrappedValue = 42

        #expect(r.hasPending == true)
        #expect(recomposeCount == 0)   // not committed yet

        r.commitAll()

        #expect(recomposeCount == 1)
        #expect(r.hasPending == false)
    }

    @Test("Binding projectedValue setter fires onChange")
    func bindingFiresOnChange() {
        var state = State(wrappedValue: "hello")
        var fired = false
        state._storage.onChange = { fired = true }

        let binding = state.projectedValue
        binding.wrappedValue = "world"

        #expect(fired == true)
        #expect(state.wrappedValue == "world")
    }

    @Test("Binding.constant ignores writes silently")
    func bindingConstant() {
        let b = Binding<Int>.constant(99)
        b.wrappedValue = 0   // no-op, must not crash
        #expect(b.wrappedValue == 99)
    }
}
