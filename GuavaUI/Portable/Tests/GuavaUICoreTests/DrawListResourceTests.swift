import Testing
import GuavaUICore

@Suite("Cached draw list ownership")
struct DrawListResourceTests {
    private final class Lease: Sendable {}

    @Test("COW and translated composites retain resources after their source is reset")
    func compositeLifetime() {
        var owner: Lease? = Lease()
        weak let observed = owner
        let cached = DrawList()
        cached.retainResource(owner!)
        cached.retainResource(owner!)
        cached.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        let frame = DrawList()
        frame.append(cached)
        frame.append(cached, vertexTranslationX: 10, vertexTranslationY: 20)
        #expect(frame.resources.count == 1 && frame.vertices.count == 8)
        owner = nil
        cached.reset()
        #expect(observed != nil)
        let restored = DrawList()
        restored.load(vertices: frame.vertices, indices: frame.indices, batches: frame.batches, resources: frame.resources)
        frame.reset()
        #expect(observed != nil)
        restored.load(vertices: [], indices: [], batches: [])
        #expect(observed == nil)
    }

    @Test("empty geometry can carry an ownership lease through append")
    func emptyGeometry() {
        var owner: Lease? = Lease()
        weak let observed = owner
        let source = DrawList(); source.retainResource(owner!)
        let frame = DrawList(); frame.append(source)
        owner = nil; source.reset()
        #expect(observed != nil)
        frame.reset()
        #expect(observed == nil)
    }
}
