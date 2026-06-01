import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime

@Suite("Phase 8 / Interpolatable")
struct InterpolatableTests {

    // MARK: - Numeric

    @Test("Float interpolation hits both ends and the midpoint")
    func floatInterp() {
        #expect(Float.interpolate(0, 10, t: 0) == 0)
        #expect(Float.interpolate(0, 10, t: 1) == 10)
        #expect(Float.interpolate(0, 10, t: 0.5) == 5)
        #expect(Float.interpolate(-4, 4, t: 0.25) == -2)
    }

    @Test("Double interpolation matches Float behavior")
    func doubleInterp() {
        #expect(Double.interpolate(0, 1, t: 0.5) == 0.5)
        #expect(Double.interpolate(10, 20, t: 0) == 10)
        #expect(Double.interpolate(10, 20, t: 1) == 20)
    }

    @Test("CGFloat interpolation")
    func cgFloatInterp() {
        #expect(CGFloat.interpolate(0, 100, t: 0.25) == 25)
    }

    // MARK: - Color

    @Test("Color interpolation lerps each channel independently")
    func colorInterp() {
        let a = Color(r: 0, g: 0, b: 0, a: 0)
        let b = Color(r: 1, g: 1, b: 1, a: 1)
        let mid = Color.interpolate(a, b, t: 0.5)
        #expect(mid.r == 0.5)
        #expect(mid.g == 0.5)
        #expect(mid.b == 0.5)
        #expect(mid.a == 0.5)
    }

    @Test("Color endpoints are exact")
    func colorEndpoints() {
        let a = Color(r: 0.2, g: 0.3, b: 0.4, a: 0.5)
        let b = Color(r: 0.8, g: 0.7, b: 0.6, a: 1.0)
        #expect(Color.interpolate(a, b, t: 0) == a)
        #expect(Color.interpolate(a, b, t: 1) == b)
    }

    @Test("Color interpolation does not premultiply alpha")
    func colorStraightAlpha() {
        let opaque = Color(r: 1, g: 0, b: 0, a: 1)
        let transparent = Color(r: 0, g: 0, b: 1, a: 0)
        let mid = Color.interpolate(opaque, transparent, t: 0.5)
        // RGB lerps independently of alpha — straight-alpha semantics.
        #expect(mid.r == 0.5)
        #expect(mid.b == 0.5)
        #expect(mid.a == 0.5)
    }

    // MARK: - Geometry

    @Test("CGRect interpolates origin and size")
    func rectInterp() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 100, y: 50, width: 20, height: 40)
        let mid = CGRect.interpolate(a, b, t: 0.5)
        #expect(mid.origin.x == 50)
        #expect(mid.origin.y == 25)
        #expect(mid.size.width == 15)
        #expect(mid.size.height == 25)
    }

    @Test("CGPoint and CGSize interpolate component-wise")
    func pointSizeInterp() {
        let p = CGPoint.interpolate(.zero, CGPoint(x: 4, y: 8), t: 0.25)
        #expect(p.x == 1)
        #expect(p.y == 2)

        let s = CGSize.interpolate(CGSize(width: 10, height: 20),
                                   CGSize(width: 20, height: 40), t: 0.5)
        #expect(s.width == 15)
        #expect(s.height == 30)
    }
}
