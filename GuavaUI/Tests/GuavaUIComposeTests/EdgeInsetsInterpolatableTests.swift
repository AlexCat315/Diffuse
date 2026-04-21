import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 / EdgeInsets Interpolatable")
struct EdgeInsetsInterpolatableTests {

    @Test("EdgeInsets interpolates each edge independently")
    func interp() {
        let a = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        let b = EdgeInsets(top: 10, leading: 20, bottom: 30, trailing: 40)
        let mid = EdgeInsets.interpolate(a, b, t: 0.5)
        #expect(mid.top == 5)
        #expect(mid.leading == 10)
        #expect(mid.bottom == 15)
        #expect(mid.trailing == 20)
    }

    @Test("EdgeInsets endpoints are exact")
    func endpoints() {
        let a = EdgeInsets(all: 4)
        let b = EdgeInsets(all: 12)
        #expect(EdgeInsets.interpolate(a, b, t: 0) == a)
        #expect(EdgeInsets.interpolate(a, b, t: 1) == b)
    }
}
