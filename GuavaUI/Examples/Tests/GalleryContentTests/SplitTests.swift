import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing

@testable import GalleryContent

@Suite("Gallery adaptive split", .serialized)
@MainActor
struct SplitTests {
    @Test(
        "Narrow, wide and touch previews present the expected panes and retain the edited draft",
        arguments: [Float(1), 2])
    func previews(scale: Float) throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(
            atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        let scheduler = AnimatorScheduler()
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer {
                    graph.install(root: EmptyView())
                    scheduler.reset()
                }
                graph.install(
                    root: AdaptiveControlExamples(page: .splitView, options: GalleryOptions()).textScaler(.init(scale))
                        .reducedMotion())
                func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
                func settle() {
                    for _ in 0..<8 {
                        graph.recomposer.commitAll()
                        graph.computeLayout(width: 900, height: 1100)
                    }
                }
                settle()
                for name in ["narrow", "wide", "touch"] {
                    let preview = try #require(
                        nodes(graph.tree.root!).first {
                            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String
                                == "adaptive-splitView-\(name)"
                        })
                    let controls = nodes(preview)
                    let details = try #require(
                        controls.first { $0.accessibility?.role == .tab && $0.accessibility?.label == "Details" })
                    let field = try #require(controls.first { $0.accessibility?.role == .textField && $0.isFocusable })
                    let fieldID = field.id
                    #expect(details.acceptsSubtreeInput == (name != "wide"))
                    if name != "wide" {
                        #expect(!field.acceptsSubtreeInput)
                        details.accessibilityActions.activate?()
                        settle()
                        #expect(field.acceptsSubtreeInput)
                    }
                    if name == "touch" { #expect(details.frame.height >= 44) }
                    context.focusChain.focus(field)
                    let input = EventDispatcher(
                        tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    input.dispatch(.textInput("Edited "))
                    settle()
                    #expect(field.resolvedAccessibilityValue.contains("Edited "))
                    if name != "wide" {
                        let navigation = try #require(
                            controls.first { $0.accessibility?.role == .tab && $0.accessibility?.label == "Navigation" }
                        )
                        navigation.accessibilityActions.activate?()
                        settle()
                        details.accessibilityActions.activate?()
                        settle()
                    }
                    #expect(nodes(preview).contains { $0.id == fieldID })
                    #expect(field.resolvedAccessibilityValue.contains("Edited "))
                }
                #expect(!graph.recomposer.hasPending)
            }
        }
    }
}
