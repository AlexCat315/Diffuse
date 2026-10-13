import Foundation
import Testing
import GuavaUIAndroid
import GuavaUICompose
import GuavaUIRuntime

private struct Content: View {
    @State var count = 0
    var body: some View {
        Button("Count \(count)") { count += 1 }
            .debugName("increment")
            .frame(width: 120, height: 48)
    }
}

@Test func androidHostRetainsContentButReleasesInputAcrossSurfaceLifetimes() throws {
    let previousText = TextEnvironmentHolder.current
    let previousFocus = FocusChainHolder.current
    let root = Content()
    let session = AndroidContentSession(scale: 1) { root }
    let first = session.prepare(pixels: SIMD2(200, 100), scale: 1, deltaTime: 0)
    let indexCount = first.indices.count
    first.reset()
    let next = session.prepare(pixels: SIMD2(200, 100), scale: 1, deltaTime: 0)
    #expect(indexCount > 0)
    #expect(next.indices.count == indexCount)
    let bounds = try #require(session.inspect().controls["increment"])
    session.didPresent()
    #expect(!session.needsFrame)
    let x = Float(bounds.midX), y = Float(bounds.midY)
    session.pointer(kind: 0, x: x, y: y)
    session.pointer(kind: 1, x: x, y: y)
    #expect(root.count == 1)
    #expect(session.needsFrame)
    session.prepare(pixels: SIMD2(200, 100), scale: 1, deltaTime: 1 / 120)
    session.didPresent()
    for _ in 0..<120 where session.needsFrame {
        session.prepare(pixels: SIMD2(200, 100), scale: 1, deltaTime: 1 / 60)
        session.didPresent()
    }
    #expect(!session.needsFrame)
    session.suspend()
    #expect(session.focusedID == nil)
    session.invalidate()
    session.prepare(pixels: SIMD2(400, 200), scale: 2, deltaTime: 0)
    session.didPresent()
    #expect(root.count == 1)
    #expect(session.logicalSize == SIMD2(200, 100))
    #expect(TextEnvironmentHolder.current?.atlas === previousText?.atlas)
    #expect(FocusChainHolder.current === previousFocus)
}
