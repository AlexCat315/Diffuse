import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 / SemanticMotion")
struct SemanticMotionTests {

    @Test(".fast resolves to theme.motion.fast.seconds")
    func fastFollowsTheme() {
        let a = Animation.semantic(.fast, in: .defaultDark)
        #expect(abs(a.duration - 0.080) < 1e-6)
    }

    @Test(".medium resolves to theme.motion.standard")
    func mediumFollowsTheme() {
        let a = Animation.semantic(.medium, in: .defaultDark)
        #expect(abs(a.duration - 0.180) < 1e-6)
    }

    @Test(".slow resolves to theme.motion.slow")
    func slowFollowsTheme() {
        let a = Animation.semantic(.slow, in: .defaultDark)
        #expect(abs(a.duration - 0.320) < 1e-6)
    }

    @Test("Light and dark default themes share motion durations")
    func lightDarkParity() {
        for ref: SemanticMotionRef in [.fast, .medium, .slow] {
            let dark = Animation.semantic(ref, in: .defaultDark)
            let light = Animation.semantic(ref, in: .defaultLight)
            #expect(dark.duration == light.duration)
        }
    }

    @Test("Custom theme motion overrides flow through")
    func customTheme() {
        var theme = Theme.defaultDark
        theme.motion.fast = .milliseconds(50)
        let a = Animation.semantic(.fast, in: theme)
        #expect(abs(a.duration - 0.050) < 1e-6)

        let snappy = Animation.semantic(.snappy, in: theme)
        #expect(abs(snappy.duration - 0.050) < 1e-6)
    }

    @Test(".snappy resolves to spring on theme.motion.fast")
    func snappyFollowsThemeFast() {
        let a = Animation.semantic(.snappy, in: .defaultDark)
        #expect(abs(a.duration - 0.080) < 1e-6)
        #expect(a.curve == .spring(response: 0.08, dampingFraction: 0.9))
    }

    @Test(".bouncy resolves to spring on theme.motion.standard")
    func bouncyFollowsThemeStandard() {
        let a = Animation.semantic(.bouncy, in: .defaultDark)
        #expect(abs(a.duration - 0.180) < 1e-6)
        #expect(a.curve == .spring(response: 0.18, dampingFraction: 0.68))
    }

    @Test("Easing bridges to a cubic-bezier AnimationCurve")
    func easingBridge() {
        let curve = Easing.standard.asAnimationCurve
        if case let .cubicBezier(c1x, c1y, c2x, c2y) = curve {
            #expect(c1x == Easing.standard.c1x)
            #expect(c1y == Easing.standard.c1y)
            #expect(c2x == Easing.standard.c2x)
            #expect(c2y == Easing.standard.c2y)
        } else {
            Issue.record("expected cubicBezier")
        }
    }
}
