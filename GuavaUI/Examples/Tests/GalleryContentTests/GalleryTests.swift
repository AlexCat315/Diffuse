import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent
@testable import GuavaUI

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
        #expect(GalleryCatalog.search("CommandPalette").map(\.page) == [.commandPalette])
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
                    graph.install(root: AdaptiveApplicationContent(content: GalleryView(initialPage: page, appearance: appearance),
                        environment: State(wrappedValue: UIEnvironment())))
                    for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 820) }
                    #expect(tree.root != nil, "Missing root for \(page)")
                    #expect(graph.layoutSnapshot().first { $0.debugName == "gallery-shell" }?.frame.height == 820,
                            "Application root collapsed for \(page)")
                    func validate(_ node: Node) {
                        let location = "\(page) node \(node.id.rawValue) \(String((node.viewTag ?? "unknown").prefix(100))) \(node.frame)"
                        #expect(node.frame.width.isFinite && node.frame.height.isFinite, "Invalid layout for \(location)")
                        #expect(node.frame.width >= 0 && node.frame.height >= 0, "Negative size for \(location)")
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
            graph.install(root: AdaptiveApplicationContent(content: GalleryView(initialPage: .button),
                environment: State(wrappedValue: UIEnvironment())))
            graph.computeLayout(width: 1280, height: 820)
            #expect(graph.tree.root != nil)
            let layout = graph.layoutSnapshot()
            let shell = layout.first { $0.debugName == "gallery-shell" }
            let content = layout.first { $0.debugName == "gallery-content" }
            #expect(shell?.absoluteFrame.height == 820)
            #expect((content?.frame.height ?? 0) > 500)
            let sections = layout.filter { $0.debugName?.hasPrefix("story-section-") == true }
            #expect(sections.count == 8)
            for preview in ["narrow", "wide", "touch"] {
                #expect(layout.contains { $0.debugName == "adaptive-button-\(preview)" })
            }
            let primary = layout.first { $0.debugName == "gallery-primary-button" }
            #expect((primary?.frame.width ?? 0) > 40)
            #expect((primary?.frame.width ?? 1000) < 200)
            for (first, second) in zip(sections, sections.dropFirst()) {
                #expect(first.absoluteFrame.maxY <= second.absoluteFrame.minY)
            }
            graph.install(root: EmptyView())
        }
    }

    @Test("Placement playground keeps its trigger ring inside the preview at large text sizes")
    func placementPreviewBounds() throws {
        let oldText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = oldText }
        for width: Float in [300, 390, 720] { for scale: Float in [1, 2] {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Box(direction: .column, alignItems: .stretch) {
                PopoverPlacementExample(options: GalleryOptions(), onAction: { _ in })
            }.frame(width: width).textScaler(.init(scale)))
            defer { graph.install(root: EmptyView()) }
            for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 1000) }
            let preview = try #require(graph.layoutSnapshot().first { $0.debugName == "popover-placement-preview" })
            func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
            let triggers = nodes(try #require(graph.tree.root)).filter {
                $0.accessibility?.role == .button && $0.accessibility?.label != nil
            }
            #expect(triggers.count == (width >= 368 ? 12 : 1))
            for trigger in triggers {
                #expect(preview.absoluteFrame.insetBy(dx: -1, dy: -1).contains(trigger.absoluteFrame))
                if width < 368 { #expect(abs(trigger.absoluteFrame.midX - preview.absoluteFrame.midX) < 1) }
            }
        } }
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
            graph.install(root: AdaptiveApplicationContent(content: GalleryView(initialPage: .button),
                environment: State(wrappedValue: UIEnvironment())))
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
