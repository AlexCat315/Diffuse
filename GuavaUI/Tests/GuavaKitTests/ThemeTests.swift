import Testing
@testable import GuavaKit

@Suite("GuavaKit theme")
struct ThemeTests {

    // MARK: - ColorScheme presets

    @Test("ColorScheme.dark has distinct surface layers")
    func darkSurfaceLayers() {
        let cs = ColorScheme.dark
        // Background is darkest, overlay is lightest in the surface stack.
        #expect(cs.background.r < cs.surface.r)
        #expect(cs.surfaceSunken.r < cs.background.r)
        #expect(cs.surfaceRaised.r > cs.surface.r)
        #expect(cs.surfaceFloating.r >= cs.surfaceRaised.r)
    }

    @Test("ColorScheme.light has expected surface layer ordering")
    func lightSurfaceLayers() {
        let cs = ColorScheme.light
        // Background is near white, surface is white.
        #expect(cs.background.r >= 0.95)
        #expect(cs.surface.r >= 0.99)
        #expect(cs.surfaceSunken.r < cs.background.r)
    }

    @Test("Status colours are semantically distinct")
    func statusColours() {
        let cs = ColorScheme.dark
        #expect(cs.success.g > 0.7)   // green-ish
        #expect(cs.warning.r > 0.7)   // warm
        #expect(cs.error.r > 0.7)     // red-ish
        #expect(cs.error.g < 0.4)
    }

    // MARK: - Typography presets

    @Test("Typography.dark has descending size scale")
    func typographyScale() {
        let t = Typography.dark
        #expect(t.display.fontSize > t.title.fontSize)
        #expect(t.title.fontSize > t.headline.fontSize)
        #expect(t.headline.fontSize > t.body.fontSize)
        #expect(t.body.fontSize > t.caption.fontSize)
    }

    @Test("Typography caption and mono exist")
    func typographySlots() {
        let t = Typography.dark
        #expect(t.caption.fontSize > 0)
        #expect(t.mono.fontSize > 0)
        #expect(t.caption.lineHeight > 0)
        #expect(t.mono.lineHeight > 0)
    }

    // MARK: - SemanticColorRef

    @Test("SemanticColorRef.success resolves to ColorScheme.success")
    func semanticColorRefResolves() {
        let cs = ColorScheme.dark
        let ref = SemanticColorRef.success
        #expect(ref.resolve(cs) == cs.success)
    }

    @Test("SemanticColorRef can resolve against any scheme")
    func semanticColorRefReusable() {
        let dark = ColorScheme.dark
        let light = ColorScheme.light
        #expect(SemanticColorRef.background.resolve(dark) == dark.background)
        #expect(SemanticColorRef.background.resolve(light) == light.background)
        #expect(SemanticColorRef.background.resolve(dark) != SemanticColorRef.background.resolve(light))
    }

    // MARK: - SemanticFontRef

    @Test("SemanticFontRef.caption resolves to Typography.caption")
    func semanticFontRefResolves() {
        let t = Typography.dark
        let ref = SemanticFontRef.caption
        #expect(ref.resolve(t) == t.caption)
    }

    @Test("SemanticFontRef reuses across typographies")
    func semanticFontRefReusable() {
        let dark = Typography.dark
        let light = Typography.light
        #expect(SemanticFontRef.caption.resolve(dark) == dark.caption)
        #expect(SemanticFontRef.caption.resolve(light) == light.caption)
    }

    // MARK: - Theme

    @Test("Theme.dark provides default dark scheme and typography")
    func themeDark() {
        let t = Theme.dark
        #expect(t.colors == .dark)
        #expect(t.typography == .dark)
        #expect(t.spacing == .standard)
        #expect(t.radius == .standard)
    }

    @Test("Theme.light provides light scheme and typography")
    func themeLight() {
        let t = Theme.light
        #expect(t.colors == .light)
        #expect(t.typography == .light)
    }

    // MARK: - UIContext theme

    @Test("UIContext starts with dark theme by default")
    func contextDefaultTheme() {
        let ctx = UIContext()
        #expect(ctx.theme.colors == .dark)
        #expect(ctx.theme.typography == .dark)
    }

    @Test("UIContext theme can be swapped")
    func contextThemeSwap() {
        let ctx = UIContext()
        ctx.theme = .light
        #expect(ctx.theme.colors == .light)
    }

    // MARK: - Semantic modifiers (applied through UINode)

    @Test("Semantic background modifier resolves colour from context theme")
    func semanticBackgroundModifier() {
        struct App: View {
            var body: some View { Element().background(.accent) }
        }
        let ctx = UIContext()
        ctx.theme = .dark
        let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.paint.background == ColorScheme.dark.accent)
    }

    @Test("Semantic foregroundColor modifier resolves colour from context theme")
    func semanticForegroundColorModifier() {
        struct App: View {
            var body: some View {
                Text("hi").foregroundColor(.onSurface)
            }
        }
        let ctx = UIContext()
        ctx.theme = .dark
        let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.textContent?.color == ColorScheme.dark.onSurface)
    }

    @Test("Semantic border modifier resolves colour from context theme")
    func semanticBorderModifier() {
        struct App: View {
            var body: some View { Element().border(.error, width: 3) }
        }
        let ctx = UIContext()
        ctx.theme = .dark
        let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.paint.border?.color == ColorScheme.dark.error)
        #expect(node.paint.border?.width == 3)
    }

    @Test("Semantic font modifier sets fontSize from typography")
    func semanticFontModifier() {
        struct App: View {
            var body: some View { Text("hi").font(.caption) }
        }
        let ctx = UIContext()
        ctx.theme = .dark
        let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.textContent?.size == Typography.dark.caption.fontSize)
    }

    @Test("Semantic modifiers are no-ops when context has no theme")
    func semanticModifierNoContext() {
        // No UIContext installed → modifiers resolve nothing.
        let node = UINode()
        // Simulate what happens: apply without context.
        let mod = _SemanticBackgroundModifier(ref: .accent)
        mod.apply(node) // should be a no-op because node.context is nil
        #expect(node.paint.background == nil)
    }

    // MARK: - SpacingScale / RadiusScale

    @Test("SpacingScale.standard has increasing values")
    func spacingScale() {
        let s = SpacingScale.standard
        #expect(s.xs < s.sm && s.sm < s.md && s.md < s.lg)
        #expect(s.lg < s.xl && s.xl < s.xxl)
    }

    @Test("RadiusScale.standard has increasing values")
    func radiusScale() {
        let r = RadiusScale.standard
        #expect(r.sm < r.md && r.md < r.lg)
        #expect(r.full > r.lg)
    }
}
