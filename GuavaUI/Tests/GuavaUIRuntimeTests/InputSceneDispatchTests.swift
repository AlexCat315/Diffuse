import Testing
import CoreGraphics
@testable import GuavaUIRuntime

/// Phase 5b dispatch-side tests. Verify that `InputScene`-driven hit-test
/// matches Node-driven hit-test, and that `FocusChain` reuses
/// `InputScene.focusables()` cached against `InputScene.version`.
@Suite("Phase 5b InputScene dispatch", .serialized)
struct InputSceneDispatchTests {

    private final class Tree {
        let render = InputScene()
        let root = Node()
        let a = Node()
        let b = Node()
        let c = Node()

        init() {
            root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            a.frame = CGRect(x: 10, y: 10, width: 80, height: 80)
            a.isFocusable = true
            b.frame = CGRect(x: 5, y: 5, width: 30, height: 30)
            b.isFocusable = true
            c.frame = CGRect(x: 100, y: 100, width: 50, height: 50)
            // c not focusable
            root.addChild(a)
            a.addChild(b)
            root.addChild(c)
            render.install(rootNode: root)
        }
    }

    // MARK: - HitTester scene parity

    @Test("HitTester(scene:) matches HitTester(rootNode:) for the same tree")
    func scenePathMatchesNodePath() {
        let t = Tree()
        for point in [CGPoint(x: 25, y: 25), CGPoint(x: 120, y: 120),
                      CGPoint(x: 5, y: 5), CGPoint(x: 95, y: 95),
                      CGPoint(x: 1000, y: 1000)] {
            let viaNode  = HitTester.hitTest(rootNode: t.root, point: point)
            let viaScene = HitTester.hitTest(scene: t.render, point: point)
            #expect(viaNode?.node === viaScene?.node)
            #expect(viaNode?.path.count == viaScene?.path.count)
        }
    }

    @Test("InputScene path respects clipsToBounds via the InputNode mirror")
    func sceneRespectsClipping() {
        let t = Tree()
        // Mark `a` as clipping; `b` lies inside `a` but `c` lies outside `a`.
        t.a.clipsToBounds = true
        t.render.inputNode(for: t.a)?.refreshFromNode()

        // A point inside `b` (10+5+5=20, 10+5+5=20 in absolute) should still hit.
        let inside = HitTester.hitTest(scene: t.render, point: CGPoint(x: 20, y: 20))
        #expect(inside?.node === t.b)

        // A point outside `a` should not be claimed by `a`'s subtree.
        let outsideA = HitTester.hitTest(scene: t.render, point: CGPoint(x: 95, y: 95))
        #expect(outsideA?.node !== t.b)
    }

    // MARK: - InputScene.version

    @Test("InputScene.version bumps on install / reconcile / tearDown")
    func versionBumps() {
        let scene = InputScene()
        let root = Node()
        let v0 = scene.version
        scene.install(rootNode: root)
        #expect(scene.version != v0)

        let v1 = scene.version
        let child = Node()
        root.addChild(child)
        scene.reconcileChildren(of: root)
        #expect(scene.version != v1)

        let v2 = scene.version
        scene.tearDown(node: child)
        #expect(scene.version != v2)
    }

    // MARK: - FocusChain caching

    @Test("FocusChain reuses InputScene focusables and respects version")
    func focusChainReusesScene() {
        let t = Tree()
        let chain = FocusChain()
        chain.inputScene = t.render

        // First traversal cycles through both focusable nodes.
        let n1 = chain.focusNext(in: t.root)
        let n2 = chain.focusNext(in: t.root)
        let n3 = chain.focusNext(in: t.root)
        #expect(n1 === t.a || n1 === t.b)
        #expect(n2 === t.a || n2 === t.b)
        #expect(n1 !== n2)
        #expect(n3 === n1) // wraps

        // Add a third focusable node; reconcile bumps version, cache invalidates.
        let d = Node()
        d.frame = CGRect(x: 150, y: 150, width: 10, height: 10)
        d.isFocusable = true
        t.root.addChild(d)
        t.render.reconcileChildren(of: t.root)

        chain.focus(nil)
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<3 {
            if let n = chain.focusNext(in: t.root) {
                seen.insert(ObjectIdentifier(n))
            }
        }
        #expect(seen.count == 3)
        #expect(seen.contains(ObjectIdentifier(d)))
    }

    @Test("FocusChain falls back to Node walk when InputScene is not wired")
    func focusChainFallback() {
        let chain = FocusChain()
        let root = Node()
        let leaf = Node()
        leaf.isFocusable = true
        root.addChild(leaf)

        let next = chain.focusNext(in: root)
        #expect(next === leaf)
    }
}
