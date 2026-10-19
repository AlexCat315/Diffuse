import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent

@Suite("Gallery list row layouts", .serialized)
@MainActor
struct ListRowLayoutTests {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func story(_ page: GalleryPage) -> AnyView {
        switch page {
        case .list: AnyView(ListStory())
        default: AnyView(SectionedListStory())
        }
    }

    @Test("Selected and unselected story rows remain visible; badges yield no title overlap after actual taps")
    func stories() throws {
        let old = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = old }
        for page in [GalleryPage.list, .sectionedList] {
            for width: Float in [330, 600, 970] { for scale: Float in [1, 2] { for dark in [false, true] {
                let context = PlatformInputContext()
                try context.withCurrent {
                    var surface = UIEnvironment(); surface.viewport.width = width
                    surface.input = width == 970 ? [.pointer, .keyboard] : [.touch, .keyboard]
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    graph.install(root: story(page).frame(width: width).surfaceEnvironment(surface)
                        .textScaler(.init(scale)).appearance(dark ? .dark : .light))
                    defer { graph.install(root: EmptyView()) }
                    func settle() { for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 2000) } }
                    settle()
                    let root = try #require(graph.tree.root)
                    let rows = nodes(root).filter { $0.accessibility?.role == .listItem }
                    #expect(rows.count >= 2)
                    for row in rows {
                        let title = try #require(nodes(row).first { $0.layoutNode?.textInputs != nil })
                        #expect(title.frame.width > 0 && title.frame.height > 0)
                        #expect(title.clipsToBounds)
                        if let badge = nodes(row).first(where: { $0.accessibility?.role == .staticText && $0.accessibility?.label == "Selected" }) {
                            #expect(title.absoluteFrame.maxX <= badge.absoluteFrame.minX)
                            let badgeText = try #require(nodes(badge).first { $0.layoutNode?.textInputs != nil })
                            #expect(badgeText.frame.height <= CGFloat(20 * scale))
                            #expect(row.absoluteFrame.insetBy(dx: -1, dy: -1).contains(badge.absoluteFrame))
                        }
                    }
                    let first = try #require(rows.first)
                    let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    let frame = first.absoluteFrame
                    let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                    dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle()
                    #expect(first.accessibility?.state.isSelected == true)
                    let title = try #require(nodes(first).first { $0.layoutNode?.textInputs != nil })
                    #expect(title.frame.width > 0 && title.frame.height > 0 && !graph.recomposer.hasPending)
                }
            } } }
        }
    }
}
