import Testing
import GuavaUIRuntime

/// `Node.transform` is what lets a subtree be scaled about a point inside
/// itself. These pin the geometry contract that everything downstream — hit
/// testing, reveal-into-view, accessibility, the platform drag regions — reads
/// through `absoluteFrame`, so a scaled node has to answer here exactly the
/// way it is drawn.
@Suite("Node transform geometry")
struct NodeTransformTests {

    private func node(x: CGFloat, y: CGFloat,
                      width: CGFloat, height: CGFloat) -> Node {
        let node = Node()
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        return node
    }

    // MARK: - Identity

    @Test("An untouched tree composes origins the way it always has")
    func identityIsTransparent() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let parent = node(x: 100, y: 50, width: 400, height: 400)
        let child = node(x: 10, y: 20, width: 50, height: 30)
        root.addChild(parent)
        parent.addChild(child)

        #expect(parent.absoluteOrigin == CGPoint(x: 100, y: 50))
        #expect(child.absoluteOrigin == CGPoint(x: 110, y: 70))
        #expect(child.absoluteFrame.size == CGSize(width: 50, height: 30))
        #expect(child.convertFromWindow(CGPoint(x: 125, y: 85)) == CGPoint(x: 15, y: 15))
    }

    // MARK: - Scale about an anchor

    @Test("Scaling about the top-left keeps the origin and shrinks the frame")
    func scaleAboutTopLeft() {
        let child = node(x: 100, y: 40, width: 200, height: 100)
        child.transform = NodeTransform(scale: 0.5, anchor: .zero)

        #expect(child.absoluteOrigin == CGPoint(x: 100, y: 40))
        #expect(child.absoluteFrame.size == CGSize(width: 100, height: 50))
    }

    @Test("Scaling about the centre pulls the origin toward the centre")
    func scaleAboutCentre() {
        let child = node(x: 100, y: 40, width: 200, height: 100)
        child.transform = NodeTransform(scale: 0.5, anchor: CGPoint(x: 0.5, y: 0.5))

        // The centre sits at (200, 90) and does not move; the box shrinks from
        // 200x100 to 100x50 around it, so the origin travels the half of the
        // width and height that came off the near edges.
        #expect(child.absoluteOrigin == CGPoint(x: 150, y: 65))
        #expect(child.absoluteFrame.size == CGSize(width: 100, height: 50))
        #expect(child.absoluteFrame.midX == 200)
        #expect(child.absoluteFrame.midY == 90)
    }

    @Test("The anchor point itself does not move, whatever the scale")
    func anchorPointIsFixed() {
        // The anchor sits on the node's own boundary — a corner, or the centre,
        // which is the midpoint of the drawn frame whichever way it was scaled.
        // Wherever it lands on screen, mapping back must return it to the same
        // local point; if the scale moved it, the round trip would not.
        for scale in [Float(0.25), 0.5, 1, 2] {
            for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
                let child = node(x: 100, y: 40, width: 200, height: 100)
                child.transform = NodeTransform(scale: scale, anchor: anchor)
                let frame = child.absoluteFrame
                let onScreen = CGPoint(x: anchor.x == 0 ? frame.minX : (anchor.x == 1 ? frame.maxX : frame.midX),
                                        y: anchor.y == 0 ? frame.minY : (anchor.y == 1 ? frame.maxY : frame.midY))
                let back = child.convertFromWindow(onScreen)
                #expect(abs(back.x - anchor.x * 200) < 1e-6)
                #expect(abs(back.y - anchor.y * 100) < 1e-6)
            }
        }
    }

    // MARK: - Composition

    @Test("A scale on an ancestor applies to the whole subtree")
    func scaleComposesDownTheTree() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let group = node(x: 100, y: 100, width: 200, height: 200)
        let child = node(x: 0, y: 0, width: 40, height: 40)
        root.addChild(group)
        group.addChild(child)
        group.transform = NodeTransform(scale: 2, anchor: .zero)

        // The group's own frame grows about its top-left, and the child sits at
        // that same point — scaled twice over, because it is inside it.
        #expect(group.absoluteFrame == CGRect(x: 100, y: 100, width: 400, height: 400))
        #expect(child.absoluteFrame == CGRect(x: 100, y: 100, width: 80, height: 80))
    }

    @Test("Nested scales multiply rather than add")
    func nestedScalesMultiply() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let outer = node(x: 0, y: 0, width: 100, height: 100)
        let inner = node(x: 0, y: 0, width: 100, height: 100)
        root.addChild(outer)
        outer.addChild(inner)
        outer.transform = NodeTransform(scale: 2, anchor: .zero)
        inner.transform = NodeTransform(scale: 3, anchor: .zero)

        #expect(inner.absoluteFrame.size == CGSize(width: 600, height: 600))
    }

    // MARK: - Pointer round trip

    /// A pointer maps back to the same local point under scale
    func convertRoundTripsUnderScale() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let child = node(x: 120, y: 60, width: 200, height: 100)
        root.addChild(child)
        child.transform = NodeTransform(scale: 0.8, anchor: CGPoint(x: 0.5, y: 0.5))

        // Drawn at 0.8 about its centre, so the centre of the drawn frame is
        // still the centre of the local one — a round trip has to land there
        // rather than on the unscaled point.
        let frame = child.absoluteFrame
        let back = child.convertFromWindow(CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(back.x - 100) < 1e-6)
        #expect(abs(back.y - 50) < 1e-6)
    }

    @Test("A collapsed node answers with a finite point rather than infinity")
    func collapsedScaleStaysFinite() {
        let child = node(x: 10, y: 10, width: 100, height: 100)
        child.transform = NodeTransform(scale: 0, anchor: .zero)
        let converted = child.convertFromWindow(CGPoint(x: 5, y: 5))
        #expect(converted.x.isFinite && converted.y.isFinite)
    }

    // MARK: - contentOffset

    /// The distinction the whole chain rests on: `contentOffset` slides a
    /// node's children, it does not move the node. A scroll view that reported
    /// its own origin scrolled would put reveal-into-view, hit testing and the
    /// platform drag regions off by exactly the scroll offset.
    @Test("A node's own scroll offset moves its children, not itself")
    func contentOffsetDoesNotMoveTheNode() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let viewport = node(x: 40, y: 20, width: 300, height: 200)
        let content = node(x: 0, y: 0, width: 300, height: 900)
        root.addChild(viewport)
        viewport.addChild(content)
        viewport.contentOffset = CGPoint(x: 0, y: 120)

        #expect(viewport.absoluteOrigin == CGPoint(x: 40, y: 20))
        #expect(content.absoluteOrigin == CGPoint(x: 40, y: -100))
    }

    @Test("Scroll offset composes with a scale on the same node")
    func contentOffsetAndScaleCompose() {
        let root = node(x: 0, y: 0, width: 800, height: 600)
        let viewport = node(x: 40, y: 20, width: 300, height: 200)
        let content = node(x: 0, y: 0, width: 300, height: 900)
        root.addChild(viewport)
        viewport.addChild(content)
        viewport.contentOffset = CGPoint(x: 0, y: 120)
        viewport.transform = NodeTransform(scale: 2, anchor: .zero)

        // The viewport still reports its own frame, unscaled and unscrolled...
        #expect(viewport.absoluteFrame == CGRect(x: 40, y: 20, width: 600, height: 400))
        // ...while its content slides by the scroll offset *before* the scale,
        // so scrolling 120pt in a box drawn at 2× moves 240pt on screen.
        #expect(content.absoluteOrigin == CGPoint(x: 40, y: -220))
    }
}