#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing
@testable import GuavaUICompose
import GuavaUIRuntime

@Suite("Portal layout")
struct PortalLayoutTests: GuavaUIComposeSerializedSuite {
    @Test("PortalHost does not participate in LayerRoot content flex")
    func portalHostDoesNotAffectContentFlex() {
        GlobalTestLock.locked {
            PortalRegistry.clear()
            PortalRegistry.register(id: "test-popover",
                                    position: CGPoint(x: 24, y: 32),
                                    width: 120,
                                    content: AnyView(
                                        Box { EmptyView() }
                                            .frame(height: 96)
                                            .debugName("portal-content")
                                    ))
            defer { PortalRegistry.clear() }

            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root:
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        Box { EmptyView() }
                            .frame(height: 40)
                            .debugName("main-header")
                        Box { EmptyView() }
                            .flex()
                            .debugName("main-fill")
                    }
                    .flex()
                    .debugName("main-content")
                } portals: {
                    PortalHost()
                }
            )

            graph.computeLayout(width: 300, height: 200)
            let snapshot = graph.layoutSnapshot()

            #expect(snapshot.first(where: { $0.debugName == "main-header" })?.absoluteFrame.height == 40)
            #expect(snapshot.first(where: { $0.debugName == "main-fill" })?.absoluteFrame.origin.y == 40)
            #expect(snapshot.first(where: { $0.debugName == "main-fill" })?.absoluteFrame.height == 160)
            #expect(snapshot.first(where: { $0.layoutRole == "portal-layer" })?.absoluteFrame.size.height == 200)
            #expect(snapshot.first(where: { $0.debugName == "test-popover" })?.absoluteFrame.origin.x == 24)
            #expect(snapshot.first(where: { $0.debugName == "test-popover" })?.absoluteFrame.origin.y == 32)
        }
    }
}
