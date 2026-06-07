import Testing
@testable import GuavaKit

@Suite("GuavaKit paint")
struct PaintTests {
    private let red = Color(r: 1, g: 0, b: 0)
    private let blue = Color(r: 0, g: 0, b: 1)

    private func node(_ frame: Rect, bg: Color? = nil, z: Float = 0, clip: Bool = false) -> UINode {
        let n = UINode(geometry: Geometry(frame: frame, zIndex: z, clipsToBounds: clip))
        if let bg { n.setPaint(Paint(background: bg)) }
        return n
    }

    @Test("Background fills at absolute coordinates")
    func backgroundAbsolute() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100))
        let a = node(Rect(x: 10, y: 20, width: 30, height: 40), bg: blue)
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        let list = Painter().paint(root: root)
        #expect(list.commands.contains(.fillRect(Rect(x: 10, y: 20, width: 30, height: 40), blue)))
    }

    @Test("Nested children accumulate parent origins")
    func nestedOrigins() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100))
        let a = node(Rect(x: 10, y: 10, width: 80, height: 80))
        let b = node(Rect(x: 5, y: 5, width: 20, height: 20), bg: red)
        root.append(a); a.append(b)
        let list = Painter().paint(root: root)
        // b absolute = (0+10+5, 0+10+5) = (15,15).
        #expect(list.commands.contains(.fillRect(Rect(x: 15, y: 15, width: 20, height: 20), red)))
    }

    @Test("Paint order is ascending z (higher z drawn last = on top)")
    func zPaintOrder() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100))
        let low = node(Rect(x: 0, y: 0, width: 50, height: 50), bg: red, z: 0)
        let high = node(Rect(x: 0, y: 0, width: 50, height: 50), bg: blue, z: 10)
        root.append(low); root.append(high)
        let list = Painter().paint(root: root)
        let redIdx = list.commands.firstIndex(of: .fillRect(Rect(x: 0, y: 0, width: 50, height: 50), red))
        let blueIdx = list.commands.firstIndex(of: .fillRect(Rect(x: 0, y: 0, width: 50, height: 50), blue))
        #expect(redIdx != nil && blueIdx != nil)
        #expect(redIdx! < blueIdx!) // low z (red) painted before high z (blue)
    }

    @Test("clipsToBounds brackets the subtree with push/pop clip")
    func clipBrackets() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100))
        let clip = node(Rect(x: 0, y: 0, width: 20, height: 20), clip: true)
        let child = node(Rect(x: 0, y: 0, width: 10, height: 10), bg: red)
        clip.append(child); root.append(clip)
        let list = Painter().paint(root: root)
        let pushIdx = list.commands.firstIndex(of: .pushClip(Rect(x: 0, y: 0, width: 20, height: 20)))
        let fillIdx = list.commands.firstIndex(of: .fillRect(Rect(x: 0, y: 0, width: 10, height: 10), red))
        let popIdx = list.commands.firstIndex(of: .popClip)
        #expect(pushIdx != nil && fillIdx != nil && popIdx != nil)
        #expect(pushIdx! < fillIdx! && fillIdx! < popIdx!) // child drawn inside the clip
    }

    @Test("contentOffset translates children")
    func contentOffsetTranslates() {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100),
                                             contentOffset: Point(x: 0, y: 10)))
        let child = node(Rect(x: 0, y: 0, width: 30, height: 30), bg: red)
        root.append(child)
        let list = Painter().paint(root: root)
        // child absolute = (0 - 0, 0 - 10) = (0, -10).
        #expect(list.commands.contains(.fillRect(Rect(x: 0, y: -10, width: 30, height: 30), red)))
    }

    // MARK: - Driven by the dirty pipe

    @Test("renderIfNeeded only rebuilds when .paint-dirty")
    func gatedRender() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100), bg: red)
        let ctx = UIContext(); ctx.install(root: root)
        // Install raised .paint → first render produces a list.
        #expect(ctx.renderIfNeeded() != nil)
        // Nothing changed → no rebuild.
        #expect(ctx.renderIfNeeded() == nil)
        // A geometry move raises .paint through the same funnel.
        root.setFrame(Rect(x: 0, y: 0, width: 120, height: 100))
        #expect(ctx.renderIfNeeded() != nil)
        #expect(ctx.renderIfNeeded() == nil)
        // A paint edit raises .paint.
        root.setPaint(Paint(background: blue))
        #expect(ctx.renderIfNeeded() != nil)
    }

    @Test("Removing a node triggers a repaint")
    func removalRepaints() {
        let root = node(Rect(x: 0, y: 0, width: 100, height: 100), bg: red)
        let a = node(Rect(x: 0, y: 0, width: 20, height: 20), bg: blue)
        root.append(a)
        let ctx = UIContext(); ctx.install(root: root)
        _ = ctx.renderIfNeeded() // drain initial
        #expect(ctx.renderIfNeeded() == nil)
        a.removeFromParent()
        let list = ctx.renderIfNeeded()
        #expect(list != nil)
        #expect(list!.commands.contains(.fillRect(Rect(x: 0, y: 0, width: 20, height: 20), blue)) == false)
    }
}
