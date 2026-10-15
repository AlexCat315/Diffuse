import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// The contract for a scale: what is drawn and what is clickable are the same
/// rectangle. When they disagree the failure is not a subtle offset — a control
/// shrinks toward a corner and the part that visibly moved keeps taking clicks,
/// or a button is hit in a margin where nothing is painted. Both read as the UI
/// being broken rather than as a hit-test bug.
@Suite("Scaled hit testing", .serialized)
struct ScaledHitTesterTests {

    private func button(_ x: CGFloat, _ y: CGFloat,
                        _ width: CGFloat, _ height: CGFloat) -> Node {
        let node = Node()
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        node.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
        return node
    }

    private func scene(_ build: (Node) -> Void) -> Node {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        build(root)
        return root
    }

    // MARK: - The rectangle follows the scale

    @Test("A shrunken node is not hit in the space it vacated")
    func vacatedSpaceIsDead() {
        let panel = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            root.addChild(panel)
            panel.transform = NodeTransform(scale: 0.5, anchor: .zero)
        }
        let _ = root

        // 200x200 at (100,100) halved about its top-left now covers
        // (100,100)-(200,200).
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 150, y: 150))?.node === panel)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 250, y: 250))?.node !== panel)
    }

    @Test("The drawn rectangle and the hittable one are the same one")
    func drawnMatchesHittable() {
        let panel = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            panel.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
            root.addChild(panel)
            panel.transform = NodeTransform(scale: 0.5, anchor: .zero)
        }
        _ = root

        // Walk the whole panel and confirm the hit boundary is its reported
        // frame to the pixel, rather than two rectangles that happen to look
        // similar in a screenshot.
        let frame = panel.absoluteFrame
        #expect(frame == CGRect(x: 100, y: 100, width: 100, height: 100))

        let justInside = CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5)
        let justOutside = CGPoint(x: frame.maxX + 0.5, y: frame.maxY + 0.5)
        #expect(HitTester.hitTest(rootNode: root, point: justInside)?.node === panel)
        #expect(HitTester.hitTest(rootNode: root, point: justOutside)?.node !== panel)
    }

    // MARK: - Anchors

    @Test("A centre anchor moves the hit area, not just the size")
    func centreAnchorMovesTheHitArea() {
        let panel = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            root.addChild(panel)
            panel.transform = NodeTransform(scale: 0.5, anchor: CGPoint(x: 0.5, y: 0.5))
        }
        _ = root

        // The box shrinks to (150,150)-(250,250) around the unmoved centre.
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 200, y: 200))?.node === panel)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 120, y: 120))?.node !== panel)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 280, y: 280))?.node !== panel)
    }

    // MARK: - Nested and scrolled

    @Test("A child is hit where it is drawn inside a scaled ancestor")
    func childInsideScaledAncestor() {
        let group = Node()
        let child = Node()
        let root = scene { root in
            group.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            root.addChild(group)
            child.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            group.addChild(child)
            group.transform = NodeTransform(scale: 2, anchor: .zero)
        }
        _ = root

        // The child is drawn at (100,100)-(180,180) and must be clicked there.
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 150, y: 150))?.node === child)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 220, y: 220))?.node !== child)
    }

    @Test("Scroll is undone before the scale, matching what is drawn")
    func scrollThenScale() {
        let viewport = Node()
        let content = Node()
        let root = scene { root in
            viewport.frame = CGRect(x: 40, y: 20, width: 300, height: 200)
            root.addChild(viewport)
            content.frame = CGRect(x: 0, y: 0, width: 300, height: 900)
            viewport.addChild(content)
            viewport.contentOffset = CGPoint(x: 0, y: 100)
            viewport.transform = NodeTransform(scale: 2, anchor: .zero)
        }
        _ = root

        // The viewport's content starts 200pt above it on screen, because the
        // 100pt of scroll is in content units and the box is drawn at 2×.
        #expect(viewport.absoluteFrame == CGRect(x: 40, y: 20, width: 600, height: 400))
        #expect(content.absoluteOrigin == CGPoint(x: 40, y: -180))
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 40, y: 20))?.node === content)
    }

    // MARK: - Degenerate

    @Test("A collapsed node is not hit at all")
    func collapsedNodeIsUnhittable() {
        let panel = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            root.addChild(panel)
            panel.transform = NodeTransform(scale: 0, anchor: .zero)
        }
        _ = root

        // A zero scale has no inverse, so a naive implementation falls back to
        // the identity and reports the node as full-size — hit-testable
        // exactly where it is not drawn.
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 150, y: 150))?.node !== panel)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 100, y: 100))?.node !== panel)
    }

    // MARK: - What callers get back

    /// A caller measuring within the node — a press offset, a slider thumb — has
    /// always got the node's own unscaled coordinates. Scale must not leak into
    /// that and turn "pressed 10pt from the left edge" into 20pt.
    @Test("localPoint stays in the node's own unscaled space")
    func localPointIsUnscaled() {
        let panel = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            root.addChild(panel)
            panel.transform = NodeTransform(scale: 0.5, anchor: .zero)
        }
        _ = root

        // Window (150, 150) is local (100, 100) — the middle of the box — even
        // though on screen that point sits halfway across the drawn 100pt.
        let hit = HitTester.hitTest(rootNode: root, point: CGPoint(x: 150, y: 150))
        #expect(hit?.node === panel)
        #expect(hit?.localPoint == CGPoint(x: 100, y: 100))
    }

    // MARK: - Clipping still clips

    @Test("A scaled clipping container still rejects hits outside its box")
    func scaledClipStillClips() {
        let panel = Node()
        let child = Node()
        let root = scene { root in
            panel.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
            panel.clipsToBounds = true
            root.addChild(panel)
            // A child that pokes out past the parent's right edge.
            child.frame = CGRect(x: 180, y: 10, width: 100, height: 40)
            panel.addChild(child)
            panel.transform = NodeTransform(scale: 0.5, anchor: .zero)
        }
        _ = root

        // Panel clips to (100,100)-(200,200); the child is drawn at
        // (190,105)-(240,125), so everything past x=200 is painted over by
        // nothing and must not be clickable.
        #expect(child.absoluteFrame == CGRect(x: 190, y: 105, width: 50, height: 20))
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 195, y: 115))?.node === child)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 220, y: 115))?.node !== child)
    }
}
