import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GuavaUIGallery

@Suite("Component gallery", .serialized)
@MainActor
struct GalleryTests {
    @Test("Every catalog entry has a unique page and can be located by name")
    func catalogCoverage() {
        #expect(Set(GalleryCatalog.entries.map(\.page)) == Set(GalleryPage.allCases))
        #expect(GalleryCatalog.entries.count == GalleryPage.allCases.count)
        for entry in GalleryCatalog.entries {
            #expect(GalleryCatalog.page(named: entry.title.lowercased()) == entry.page)
            #expect(GalleryCatalog.search(entry.title).contains { $0.page == entry.page })
        }
        #expect(GalleryCatalog.search("keyboard slider").map(\.page) == [.slider])
        #expect(GalleryCatalog.search("no-such-component").isEmpty)
    }

    @Test("All stories materialize and settle in light and dark themes")
    func allStories() {
        let oldText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        let oldInteractions = InteractionRegistryHolder.current
        let oldFocus = FocusChainHolder.current
        let oldCapture = PointerCaptureHolder.current
        defer {
            TextEnvironmentHolder.current = oldText
            InteractionRegistryHolder.current = oldInteractions
            FocusChainHolder.current = oldFocus
            PointerCaptureHolder.current = oldCapture
        }
        AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            for appearance: Appearance in [.light, .dark] {
                for page in GalleryPage.allCases {
                    InteractionRegistryHolder.current = InteractionRegistry()
                    FocusChainHolder.current = FocusChain()
                    PointerCaptureHolder.current = PointerCapture()
                    let tree = NodeTree()
                    let graph = ViewGraph(tree: tree, recomposer: Recomposer())
                    graph.install(root: GalleryView(initialPage: page, appearance: appearance))
                    for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 820) }
                    #expect(tree.root != nil, "Missing root for \(page)")
                    func validate(_ node: Node) {
                        #expect(node.frame.width.isFinite && node.frame.height.isFinite, "Invalid layout for \(page)")
                        #expect(node.frame.width >= 0 && node.frame.height >= 0, "Negative size for \(page)")
                        node.children.forEach(validate)
                    }
                    if let root = tree.root { validate(root) }
                    let sections = graph.layoutSnapshot().filter { $0.debugName?.hasPrefix("story-section-") == true }
                    for section in sections { #expect(section.frame.height > 60, "Collapsed section for \(page)") }
                    for (first, second) in zip(sections, sections.dropFirst()) {
                        #expect(first.absoluteFrame.maxY <= second.absoluteFrame.minY, "Overlapping sections for \(page)")
                    }
                    if page == .tree {
                        #expect(graph.layoutSnapshot().first { $0.debugName == "gallery-tree" }?.frame.height == 250)
                    }
                    graph.install(root: EmptyView())
                    AnimatorScheduler.current.tick(deltaTime: 1)
                }
            }
        }
    }

    @Test("The gallery shell materializes with a selected story")
    func shell() {
        let oldText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = oldText }
        AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: GalleryView(initialPage: .button))
            graph.computeLayout(width: 1280, height: 820)
            #expect(graph.tree.root != nil)
            let layout = graph.layoutSnapshot()
            let shell = layout.first { $0.debugName == "gallery-shell" }
            let content = layout.first { $0.debugName == "gallery-content" }
            #expect(shell?.absoluteFrame.height == 820)
            #expect((content?.frame.height ?? 0) > 500)
            let sections = layout.filter { $0.debugName?.hasPrefix("story-section-") == true }
            #expect(sections.count == 4)
            let primary = layout.first { $0.debugName == "gallery-primary-button" }
            #expect((primary?.frame.width ?? 0) > 40)
            #expect((primary?.frame.width ?? 1000) < 200)
            for (first, second) in zip(sections, sections.dropFirst()) {
                #expect(first.absoluteFrame.maxY <= second.absoluteFrame.minY)
            }
            graph.install(root: EmptyView())
        }
    }

    @Test("Rating commits pointer input through the actual gallery's nested scroll content")
    func ratingPointer() {
        let oldText = TextEnvironmentHolder.current, oldRegistry = InteractionRegistryHolder.current
        let oldFocus = FocusChainHolder.current, oldCapture = PointerCaptureHolder.current
        defer {
            TextEnvironmentHolder.current = oldText; InteractionRegistryHolder.current = oldRegistry
            FocusChainHolder.current = oldFocus; PointerCaptureHolder.current = oldCapture
        }
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
        InteractionRegistryHolder.current = registry; FocusChainHolder.current = focus; PointerCaptureHolder.current = capture
        AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: GalleryView(initialPage: .rating))
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
            func settle() { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 720) }
            settle()
            let node = nodes(graph.tree.root!).first { $0.accessibility?.label == "Overall rating" }!
            let frame = node.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(frame.minX) + 8 + 3 * 32 + 10, y: Float(frame.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(event)); settle()
            dispatcher.dispatch(.mouseButtonUp(event)); settle()
            #expect(node.accessibility?.value == "4.0" && focus.focused === node && capture.target == nil)
            dispatcher.dispatch(.mouseButtonDown(event)); settle()
            dispatcher.dispatch(.mouseButtonUp(event)); settle()
            #expect(node.accessibility?.value == "0.0")
            graph.install(root: EmptyView())
        }
    }

    @Test("Pointer activation survives the frame between press and release")
    func navigationActivation() {
        let oldText = TextEnvironmentHolder.current
        let oldInteractions = InteractionRegistryHolder.current
        let oldFocus = FocusChainHolder.current
        let oldCapture = PointerCaptureHolder.current
        defer {
            TextEnvironmentHolder.current = oldText
            InteractionRegistryHolder.current = oldInteractions
            FocusChainHolder.current = oldFocus
            PointerCaptureHolder.current = oldCapture
        }
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        let interactions = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
        InteractionRegistryHolder.current = interactions
        FocusChainHolder.current = focus
        PointerCaptureHolder.current = capture
        AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: GalleryView())
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: interactions, capture: capture, focusChain: focus)
            func settle() { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 820) }
            func click(_ name: String) {
                settle()
                let frame = graph.layoutSnapshot().first { $0.debugName == name }!.absoluteFrame
                let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: event.x, y: event.y, deltaX: 0, deltaY: 0)))
                settle()
                dispatcher.dispatch(.mouseButtonDown(event))
                settle()
                dispatcher.dispatch(.mouseButtonUp(event))
                settle()
            }
            click("gallery-primary-button")
            func texts(_ node: Node) -> [String] {
                let own = graph.layoutNode(for: node)?.textInputs.map { [$0.text] } ?? []
                return own + node.children.flatMap(texts)
            }
            #expect(texts(graph.tree.root!).contains("Actions: 1"))
            click("sidebar-item-checkbox")
            #expect(graph.layoutSnapshot().contains { $0.debugName == "story-section-Selection" })
            graph.install(root: EmptyView())
        }
    }
}
