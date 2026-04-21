import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Theme")
struct ThemeTests {

    @Test("DefaultDarkTheme produces a stable Theme value")
    func defaultDarkIsStable() {
        let a = Theme.defaultDark
        let b = Theme.defaultDark
        #expect(a.colors.accent == b.colors.accent)
        #expect(a.spacing.md == b.spacing.md)
        #expect(a.typography.body.font == b.typography.body.font)
    }

    @Test("DefaultDarkTheme color slots are non-clear")
    func defaultDarkSlotsArePopulated() {
        let c = Theme.defaultDark.colors
        for color in [c.background, c.surface, c.onSurface, c.accent,
                      c.success, c.warning, c.error, c.info,
                      c.border, c.divider] {
            #expect(color.a > 0)
        }
    }

    @Test("Spacing / radius scales are monotonic")
    func scalesAreMonotonic() {
        let s = Theme.defaultDark.spacing
        #expect(s.xs < s.sm)
        #expect(s.sm < s.md)
        #expect(s.md < s.lg)
        #expect(s.lg < s.xl)
        #expect(s.xl < s.xxl)

        let r = Theme.defaultDark.radius
        #expect(r.none < r.sm)
        #expect(r.sm < r.md)
        #expect(r.md < r.lg)
        #expect(r.lg < r.xl)
        #expect(r.xl < r.pill)
    }

    @Test("Typography lineHeight is at least font size")
    func typographyLineHeightCoversFontSize() {
        let t = Theme.defaultDark.typography
        for token in [t.display, t.title, t.headline, t.body, t.bodyStrong,
                      t.caption, t.label, t.mono] {
            #expect(token.lineHeight >= token.font.size)
        }
    }

    @Test("Theme is a value type — mutating a copy does not affect the default")
    func themeIsValueType() {
        var copy = Theme.defaultDark
        let originalAccent = Theme.defaultDark.colors.accent
        copy.colors.accent = Color(r: 1, g: 0, b: 0)
        #expect(Theme.defaultDark.colors.accent == originalAccent)
        #expect(copy.colors.accent != originalAccent)
    }

    @Test("Theme can be provided through a CompositionLocal")
    func themeFlowsThroughCompositionLocal() {
        let themeKey = CompositionLocal<Theme>(defaultValue: .defaultDark)
        let node = Node()
        var custom = Theme.defaultDark
        custom.colors.accent = Color(r: 0.9, g: 0.2, b: 0.4)
        node.setCompositionValue(themeKey, custom)
        #expect(node.compositionValue(of: themeKey).colors.accent
                == Color(r: 0.9, g: 0.2, b: 0.4))
    }
}
