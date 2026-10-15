import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct BrandTokens: ThemeExtension {
    var editorial = TextStyleToken(font: .named("Helvetica Neue", size: 19, weight: .bold), lineHeight: 28)
    var gutter: Float = 27
    static let defaultValue = BrandTokens()
}

private struct DynamicScaleScene: View {
    @State private var scale: Float = 1
    var body: some View {
        Column {
            Button("Enlarge") { scale = 2 }.debugName("enlarge")
            LayerRoot {
                Column {
                    Text("Dynamic").font(.body)
                    Icon(UIIcons.Action.check).debugName("dynamic-icon")
                    Button(icon: .resource(UIIcons.Action.check)) {}.debugName("dynamic-icon-button")
                    Button(icon: .resource(UIIcons.Action.check), isLoading: true) {}.debugName("dynamic-loading-button")
                    TextField(text: .constant("Edit me")).font(.body).frame(width: 300).debugName("dynamic-field")
                    Popover(isPresented: .constant(true), width: 300, label: { Text("Anchor") }, content: {
                        Text("Dynamic overlay").font(.body)
                        Icon(UIIcons.Action.check).debugName("dynamic-overlay-icon")
                    })
                }
            }.textScaler(TextScaler(scale))
        }.theme(.defaultLight)
    }
}

@Suite("Application design system", .serialized)
struct DesignSystemTests: GuavaUIComposeSerializedSuite {
    private func fixture(_ work: (ViewGraph) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let text = TextEnvironmentHolder.current, portals = PortalStoreHolder.current
            TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
            PortalStoreHolder.current = PortalStore()
            defer { TextEnvironmentHolder.current = text; PortalStoreHolder.current = portals }
            try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()) }
                try work(graph)
            }
        }
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 900, height: 700) }
    }
    private func text(_ value: String, in graph: ViewGraph) -> Node {
        func find(_ node: Node) -> Node? {
            if node.layoutNode?.textInputs?.text == value { return node }
            return node.children.compactMap(find).first
        }
        return find(graph.tree.root!)!
    }

    @Test("Local themes carry custom roles, named families and open metrics without changing sibling themes")
    func customRoles() {
        fixture { graph in
            var app = Theme.defaultLight
            app.typography.family = "Helvetica Neue"
            app.typography.body = .init(font: .system(size: 16), lineHeight: 24)
            app.extensions[BrandTokens.self].gutter = 31
            var page = app
            page.extensions[BrandTokens.self].editorial = .init(font: .named("Menlo", size: 21), lineHeight: 29)
            page.typography.body = .init(font: .system(size: 18), lineHeight: 26)
            let editorial = SemanticFontRef { $0.extensions[BrandTokens.self].editorial }
            let gutter = ThemeMetric { $0.extensions[BrandTokens.self].gutter }
            graph.install(root: Column {
                Text("Application")
                Column {
                    Text("Page")
                    Text("Editorial").font(editorial).padding(gutter)
                    Text("Escape").textStyle(.init(font: .named("Menlo", size: 23), lineHeight: 32))
                    Text("Numeric size").font(.system(size: 23))
                    Text("Local title").font(.title).theme(page)
                }.theme(page)
            }.theme(app))
            settle(graph)
            #expect(text("Application", in: graph).layoutNode?.textMeasure?.key.font == .named("Helvetica Neue", size: 16))
            #expect(text("Page", in: graph).layoutNode?.textMeasure?.key.font == .named("Helvetica Neue", size: 18))
            #expect(text("Editorial", in: graph).layoutNode?.textMeasure?.key.font == .named("Menlo", size: 21))
            #expect(text("Editorial", in: graph).layoutNode?.resolvedPadding.left == 31)
            #expect(text("Escape", in: graph).layoutNode?.textMeasure?.key.font == .named("Menlo", size: 23))
            #expect(text("Numeric size", in: graph).layoutNode?.textMeasure?.key.font == .named("Helvetica Neue", size: 23))
            #expect(abs((text("Numeric size", in: graph).layoutNode?.textMeasure?.key.lineHeight ?? 0) - 26 * 23 / 18) < 0.01)
            #expect(text("Local title", in: graph).layoutNode?.textMeasure?.key.font == .named("Helvetica Neue", size: 24, weight: .bold))
            #expect(app.extensions[BrandTokens.self].editorial.font.size == 19)
            page.extensions.remove(BrandTokens.self)
            #expect(page.extensions[BrandTokens.self].gutter == BrandTokens.defaultValue.gutter)
        }
    }

    @Test("Scaling affects measurement, paint and editing once, with a nearest-scope override")
    func scaling() throws {
        try fixture { graph in
            graph.install(root: Column {
                Text("Body").font(.body)
                Text("Local").font(.body).textScaler(.init(1.5))
                Text("Default")
                Button("Action") {}.debugName("scaled-button")
                Button("Warning") {}.buttonStyle(.warning).debugName("scaled-status-button")
                Button("Tab") {}.buttonStyle(.tab).debugName("scaled-tab-button")
                TextField(text: .constant("English AV 中文")).font(.body).frame(width: 300).debugName("scaled-input")
            }.textScaler(.init(2)).theme(.defaultLight))
            settle(graph)
            let body = text("Body", in: graph), local = text("Local", in: graph)
            #expect(body.layoutNode?.textMeasure?.key.font.size == 28)
            #expect(body.layoutNode?.textMeasure?.key.lineHeight == 40)
            #expect(local.layoutNode?.textMeasure?.key.font.size == 21)
            #expect(local.layoutNode?.textMeasure?.key.lineHeight == 30)
            #expect(text("Default", in: graph).layoutNode?.textMeasure?.key.font.size == 28)
            body.draw?(DrawList(), .zero)
            #expect(body.layoutNode?.textMeasure?.key.font.size == 28)
            let snapshots = graph.layoutSnapshot()
            #expect((snapshots.first { $0.debugName == "scaled-button" }?.frame.height ?? 0) >= 44)
            #expect(snapshots.first { $0.debugName == "scaled-status-button" }?.frame.height == snapshots.first { $0.debugName == "scaled-button" }?.frame.height)
            #expect((snapshots.first { $0.debugName == "scaled-tab-button" }?.frame.height ?? 0) >= 44)
            #expect((snapshots.first { $0.debugName == "scaled-input" }?.frame.height ?? 0) >= 40)
            func field(_ node: Node) -> Node? {
                node.attachments[TextField.surfaceMarkerKey] as? Bool == true ? node : node.children.compactMap(field).first
            }
            let input = try #require(field(graph.tree.root!))
            input.draw?(DrawList(), .zero)
            let cached = try #require(input.attachments["__textfield_render_cache"] as? TextField.LayoutEngine.RenderCacheEntry)
            #expect(cached.key.font.size == 28 && cached.key.lineHeight == 40)
            #expect(TextScaler(.nan) == .identity && TextScaler(-2) == .identity)
        }
    }

    @Test("Detached overlays inherit the presenting theme, its extensions and text scale")
    func overlayScope() {
        fixture { graph in
            var theme = Theme.defaultLight
            theme.typography.body = .init(font: .system(size: 18), lineHeight: 26)
            theme.extensions[BrandTokens.self].editorial = .init(font: .system(size: 22), lineHeight: 30)
            graph.install(root: LayerRoot {
                Popover(isPresented: .constant(true), width: 300, label: { Text("Trigger") }, content: {
                    Text("Overlay").font(.body)
                    Text("Overlay extension").font(SemanticFontRef { $0.extensions[BrandTokens.self].editorial })
                }).theme(theme).textScaler(.init(1.5))
            })
            settle(graph)
            #expect(text("Overlay", in: graph).layoutNode?.textMeasure?.key.font.size == 27)
            #expect(text("Overlay", in: graph).layoutNode?.textMeasure?.key.lineHeight == 39)
            #expect(text("Overlay extension", in: graph).layoutNode?.textMeasure?.key.font.size == 33)
        }
    }

    @Test("Icon roles and resource replacements obey local themes; explicit points remain an escape hatch")
    func icons() {
        fixture { graph in
            var theme = Theme.defaultLight
            theme.icons.medium = 29
            theme.icons.replace(UIIcons.Action.check, with: UIIcons.Action.x)
            graph.install(root: Row {
                Icon(UIIcons.Action.check).debugName("semantic-icon")
                Icon(UIIcons.Action.check, size: 17).debugName("explicit-icon")
                ButtonIcon(.resource(UIIcons.Action.check)).debugName("button-icon")
            }.theme(theme))
            settle(graph)
            #expect(graph.layoutSnapshot().first { $0.debugName == "semantic-icon" }?.frame.width == 29)
            #expect(graph.layoutSnapshot().first { $0.debugName == "explicit-icon" }?.frame.width == 17)
            #expect(graph.layoutSnapshot().first { $0.debugName == "button-icon" }?.frame.width == 29)
            #expect(theme.icons.resolve(UIIcons.Action.check).description == UIIcons.Action.x.description)
            #expect(Theme.defaultLight.icons.resolve(UIIcons.Action.check).description == UIIcons.Action.check.description)
        }
    }

    @Test("A live scale change invalidates layout and updates an already open portal")
    func dynamicScaling() throws {
        try fixture { graph in
            let interactions = InteractionRegistry(), capture = PointerCapture(), focus = FocusChain()
            let oldInteractions = InteractionRegistryHolder.current, oldCapture = PointerCaptureHolder.current, oldFocus = FocusChainHolder.current
            InteractionRegistryHolder.current = interactions; PointerCaptureHolder.current = capture; FocusChainHolder.current = focus
            defer { InteractionRegistryHolder.current = oldInteractions; PointerCaptureHolder.current = oldCapture; FocusChainHolder.current = oldFocus }
            graph.install(root: DynamicScaleScene())
            settle(graph)
            #expect(text("Dynamic", in: graph).layoutNode?.textMeasure?.key.font.size == 14)
            #expect(graph.layoutSnapshot().first { $0.debugName == "dynamic-icon" }?.frame.width == 16)
            let rect = try #require(graph.layoutSnapshot().first { $0.debugName == "enlarge" }?.absoluteFrame)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: interactions, capture: capture, focusChain: focus)
            let event = MouseButtonEvent(button: .left, x: Float(rect.midX), y: Float(rect.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
            settle(graph)
            #expect(text("Dynamic", in: graph).layoutNode?.textMeasure?.key.font.size == 28)
            #expect(text("Dynamic overlay", in: graph).layoutNode?.textMeasure?.key.font.size == 28)
            #expect(graph.layoutSnapshot().first { $0.debugName == "dynamic-icon" }?.frame.width == 32)
            #expect(graph.layoutSnapshot().first { $0.debugName == "dynamic-overlay-icon" }?.frame.height == 32)
            #expect((graph.layoutSnapshot().first { $0.debugName == "dynamic-icon-button" }?.frame.height ?? 0) >= 46)
            #expect(graph.layoutSnapshot().first { $0.debugName == "dynamic-loading-button" }?.frame.height == 46)
            #expect((graph.layoutSnapshot().first { $0.debugName == "dynamic-field" }?.frame.height ?? 0) >= 40)
        }
    }

    @Test("Icons scale once for bundle, file and texture sources, including explicit sizes and custom semantic roles")
    func iconScaling() throws {
        try fixture { graph in
            let path = try #require(UIIcons.Action.check.url?.path)
            let custom = SemanticIconSize { $0.extensions[BrandTokens.self].gutter }
            graph.install(root: Row {
                Icon(UIIcons.Action.check).debugName("default-glyph")
                Icon(UIIcons.Action.check, size: 19).debugName("numeric-glyph")
                Icon(UIIcons.Action.check, size: custom).debugName("custom-glyph")
                ButtonIcon(.resource(UIIcons.Action.check)).debugName("resource-glyph")
                ButtonIcon(.file(path: path)).debugName("file-glyph")
                ButtonIcon(.texture(1)).debugName("texture-glyph")
                Icon(UIIcons.Action.check).iconScaling(.fixed).debugName("fixed-glyph")
                Icon(UIIcons.Action.check).iconScaling(.factor(1.5)).debugName("override-glyph")
                Icon(UIIcons.Action.check).textScaler(.init(1.25)).debugName("nearer-text-glyph")
            }.theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let expected: [String: CGFloat] = ["default-glyph": 32, "numeric-glyph": 38, "custom-glyph": 54,
                "resource-glyph": 32, "file-glyph": 32, "texture-glyph": 32, "fixed-glyph": 16,
                "override-glyph": 24, "nearer-text-glyph": 20]
            for (name, points) in expected {
                let frame = try #require(graph.layoutSnapshot().first { $0.debugName == name }?.frame)
                #expect(frame.width == points && frame.height == points)
            }
        }
    }

    @Test("Theme icon policy and local overrides propagate through detached overlays")
    func overlayIconPolicy() {
        fixture { graph in
            var theme = Theme.defaultLight
            theme.icons.scaling = .fixed
            graph.install(root: LayerRoot {
                Column {
                    Icon(UIIcons.Action.check).debugName("theme-fixed-icon")
                    Popover(isPresented: .constant(true), width: 200, label: { Text("Anchor") }) {
                        Icon(UIIcons.Action.check).debugName("local-overlay-icon")
                    }.iconScaling(.factor(1.5))
                }.theme(theme).textScaler(.init(2))
            })
            settle(graph)
            #expect(graph.layoutSnapshot().first { $0.debugName == "theme-fixed-icon" }?.frame.width == 16)
            #expect(graph.layoutSnapshot().first { $0.debugName == "local-overlay-icon" }?.frame.height == 24)
        }
    }

    @Test("Icon buttons keep square chrome as glyphs grow; loading replaces the glyph and retains its accessible name")
    func iconButtons() throws {
        try fixture { graph in
            graph.install(root: Row {
                Button(icon: .texture(1), tooltip: "Settings") {}.debugName("icon-only-normal")
                Button(icon: .texture(1), isLoading: true, tooltip: "Saving") {}.debugName("icon-only-loading")
                Button(icon: .texture(1), tooltip: "Fixed") {}.iconScaling(.fixed).debugName("icon-only-fixed")
            }.theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let normal = try #require(graph.layoutSnapshot().first { $0.debugName == "icon-only-normal" }?.frame)
            let loading = try #require(graph.layoutSnapshot().first { $0.debugName == "icon-only-loading" }?.frame)
            let fixed = try #require(graph.layoutSnapshot().first { $0.debugName == "icon-only-fixed" }?.frame)
            #expect(normal.width == 46 && normal.height == 46)
            #expect(loading.size == normal.size && fixed.width == 32 && fixed.height == 32)
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let nodes = all(graph.tree.root!)
            let saving = try #require(nodes.first { $0.accessibility?.label == "Saving" })
            #expect(saving.accessibility?.role == .button && saving.accessibility?.state.isEnabled == false)
            let spinner = try #require(all(saving).first { $0.viewTag?.hasSuffix(".Spinner") == true })
            #expect(all(saving).filter { $0.viewTag?.hasSuffix(".Spinner") == true }.count == 1)
            let ink = try #require(spinner.inheritedForegroundColor)
            let paint = DrawList(); spinner.draw?(paint, .zero)
            let vertex = try #require(paint.vertices.last)
            #expect(abs(Int(vertex.color & 255) - Int((ink.r * 255).rounded())) <= 1)
            #expect(abs(Int((vertex.color >> 16) & 255) - Int((ink.b * 255).rounded())) <= 1)
            #expect(!all(saving).contains { $0.viewTag?.hasSuffix(".Image") == true })
        }
    }

    @Test("ButtonIcon explicit tint has the same meaning for resource, file and texture sources")
    func iconTint() throws {
        try fixture { graph in
            let tint = Color(r: 0.2, g: 0.6, b: 0.3)
            let sources: [ButtonIcon.Source] = [.resource(UIIcons.Action.check), .texture(1), .file(path: "/missing-icon.png")]
            graph.install(root: Row {
                for source in sources { ButtonIcon(source, tint: tint) }
            }.foregroundColor(.onAccent).theme(.defaultLight))
            settle(graph)
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let images = all(graph.tree.root!).filter { $0.viewTag?.contains(".Image") == true }
            #expect(images.count == 3)
            for image in images {
                let paint = DrawList(); image.draw?(paint, .zero)
                let vertex = try #require(paint.vertices.first)
                #expect(abs(Int(vertex.color & 255) - 51) <= 1)
                #expect(abs(Int((vertex.color >> 8) & 255) - 153) <= 1)
                #expect(abs(Int((vertex.color >> 16) & 255) - 77) <= 1)
            }
        }
    }

    @Test("Menu takes the shared glass material, and its visible-row budget follows body typography and scale")
    func readableMenus() throws {
        try fixture { graph in
            graph.install(root: Menu([
                .item(MenuItem(id: "one", title: "First", isSelected: true) {}),
                .item(MenuItem(id: "two", title: "Second") {})
            ], width: 300, maxVisibleRows: 2).theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let first = text("First", in: graph)
            #expect(first.layoutNode?.textMeasure?.key.font.size == 28)
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let nodes = all(graph.tree.root!)
            // Glass, like every other floating panel — and translucent, which is
            // what lets the frost behind it show through at all.
            let panel = try #require(nodes.first {
                $0.backgroundColor == Theme.defaultLight.colors.surfaceMaterial && $0.cornerRadius > 0
            })
            #expect(panel.backdropBlur > 0)
            #expect(panel.frame.height >= 104)
            #expect(nodes.filter { $0.attachments["__menu_item_id"] != nil }.allSatisfy { $0.frame.height >= 52 })
        }
    }

    @Test("A scaled Combobox keeps its input focus, filters live, displays emptiness and commits through the dispatcher")
    func scaledCombobox() throws {
        try fixture { graph in
            final class Selection { var value: Int? }
            let selection = Selection()
            let context = PlatformInputContext()
            try context.withCurrent {
                graph.install(root: LayerRoot {
                    Combobox(selection: Binding(get: { selection.value }, set: { selection.value = $0 }), options: [
                        SelectOption(value: 1, label: "Alpha"), SelectOption(value: 2, label: "Unavailable", isEnabled: false),
                        SelectOption(value: 3, label: "Beta")
                    ]).debugName("scaled-combobox")
                }.theme(.defaultLight).textScaler(.init(2)))
                settle(graph)
                let frame = try #require(graph.layoutSnapshot().first { $0.debugName == "scaled-combobox" }?.absoluteFrame)
                #expect(frame.height >= 48)
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                let click = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(click)); dispatcher.dispatch(.mouseButtonUp(click)); settle(graph)
                #expect(context.focusChain.focused?.accessibility?.label == "Search…")
                dispatcher.dispatch(.textInput("Beta")); settle(graph)
                #expect(text("Beta", in: graph).layoutNode?.textMeasure?.key.font.size == 26)
                func replaceQuery(_ query: String) {
                    dispatcher.dispatch(.keyDown(KeyEvent(scancode: 4, keycode: 0,
                        modifiers: KeyboardShortcutPlatform.current == .macOS ? [.lgui] : [.lctrl], isRepeat: false)))
                    dispatcher.dispatch(.textInput(query)); settle(graph)
                }
                replaceQuery("missing")
                #expect(text("No matching options", in: graph).layoutNode?.textMeasure?.key.font.size == 24)
                replaceQuery("Beta")
                dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
                settle(graph)
                #expect(selection.value == 3)
                #expect(PortalStoreHolder.current.entries.isEmpty)
            }
        }
    }
}
