import Testing
@testable import GuavaKit

@Suite("GuavaKit layout")
struct LayoutTests {

    private let engine = StackLayoutEngine()

    private func node(_ style: (inout LayoutStyle) -> Void) -> UINode {
        let n = UINode()
        var s = LayoutStyle()
        style(&s)
        n.setLayoutStyle(s)
        return n
    }

    @Test("Column stack positions children with spacing; auto parent fits content")
    func columnStack() {
        let root = node { $0.direction = .column; $0.spacing = 10 }
        let a = node { $0.width = .points(50); $0.height = .points(30) }
        let b = node { $0.width = .points(40); $0.height = .points(20) }
        root.append(a); root.append(b)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))

        #expect(a.geometry.frame == Rect(x: 0, y: 0, width: 50, height: 30))
        #expect(b.geometry.frame == Rect(x: 0, y: 40, width: 40, height: 20)) // 30 + spacing 10
        // auto root fits content: height 30+10+20=60, width max(50,40)=50.
        #expect(root.geometry.frame == Rect(x: 0, y: 0, width: 50, height: 60))
    }

    @Test("flexGrow distributes leftover main-axis space")
    func flexGrow() {
        let root = node { $0.direction = .column; $0.width = .points(50); $0.height = .points(100) }
        let a = node { $0.width = .points(50); $0.flexGrow = 1 }
        let b = node { $0.width = .points(50); $0.flexGrow = 1 }
        root.append(a); root.append(b)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))

        #expect(a.geometry.frame == Rect(x: 0, y: 0, width: 50, height: 50))
        #expect(b.geometry.frame == Rect(x: 0, y: 50, width: 50, height: 50))
    }

    @Test("LayoutStyle.flexShrink is present and defaults to 0")
    func flexShrinkDefault() {
        let style = LayoutStyle()
        #expect(style.flexGrow == 0)
        #expect(style.flexShrink == 0)
    }

    @Test("padding offsets children")
    func padding() {
        let root = node { $0.padding = .all(10); $0.width = .points(100); $0.height = .points(100) }
        let a = node { $0.width = .points(20); $0.height = .points(20) }
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))
        #expect(a.geometry.frame == Rect(x: 10, y: 10, width: 20, height: 20))
    }

    @Test("alignItems .center centers on the cross axis")
    func alignCenter() {
        let root = node { $0.direction = .column; $0.alignItems = .center
                          $0.width = .points(100); $0.height = .points(100) }
        let a = node { $0.width = .points(20); $0.height = .points(20) }
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))
        #expect(a.geometry.frame == Rect(x: 40, y: 0, width: 20, height: 20)) // (100-20)/2
    }

    @Test("justifyContent .center centers on the main axis")
    func justifyCenter() {
        let root = node { $0.direction = .column; $0.justifyContent = .center
                          $0.width = .points(40); $0.height = .points(100) }
        let a = node { $0.width = .points(40); $0.height = .points(20) }
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))
        #expect(a.geometry.frame == Rect(x: 0, y: 40, width: 40, height: 20)) // (100-20)/2
    }

    @Test("percent dimensions resolve against the parent")
    func percent() {
        let root = node { $0.width = .points(100); $0.height = .points(100) }
        let a = node { $0.width = .percent(50); $0.height = .percent(25) }
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 200, height: 200))
        #expect(a.geometry.frame == Rect(x: 0, y: 0, width: 50, height: 25))
    }

    // MARK: - Integration with Stage 1's invalidation pipe

    @Test("A re-layout that moves a node invalidates the hit cache (closes the loop)")
    func relayoutInvalidatesHitCache() {
        let root = node { $0.direction = .column; $0.width = .points(100); $0.height = .points(100) }
        let a = node { $0.width = .points(100); $0.height = .points(20) }
        let b = node { $0.width = .points(100); $0.height = .points(20) }
        root.append(a); root.append(b)
        let ctx = UIContext(); ctx.install(root: root)
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 100, height: 100))

        // b is at y=20..40. Prime a hit at (50,30) → b.
        #expect(ctx.hitTest(Point(x: 50, y: 30))?.node === b)
        #expect(ctx.hitTest(Point(x: 50, y: 30))?.node === b)
        #expect(ctx.hitIndex.hits == 1)

        // Grow a → pushes b down past y=30. Re-layout writes new frames via
        // setFrame, which must have dropped the hit cache automatically.
        a.modifyLayout { $0.height = .points(50) }
        ctx.layoutIfNeeded(engine: engine, available: Size(width: 100, height: 100))

        let after = ctx.hitTest(Point(x: 50, y: 30))
        #expect(after?.node === a)            // (50,30) now lands in the grown a
        #expect(ctx.hitIndex.misses == 2)     // re-walked, not served stale
    }

    @Test("layoutIfNeeded is a no-op when nothing changed")
    func gatedLayout() {
        let root = node { $0.width = .points(100); $0.height = .points(100) }
        let ctx = UIContext(); ctx.install(root: root)
        #expect(ctx.layoutIfNeeded(engine: engine, available: Size(width: 100, height: 100)) == true)
        // Same size, no dirty → skip.
        #expect(ctx.layoutIfNeeded(engine: engine, available: Size(width: 100, height: 100)) == false)
        // Resize forces a pass.
        #expect(ctx.layoutIfNeeded(engine: engine, available: Size(width: 120, height: 100)) == true)
    }
}
