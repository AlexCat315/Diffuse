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
    @Test("PortalHost keeps rendering its owning window store after the ambient changes")
    func portalHostKeepsOwningStore() {
        GlobalTestLock.locked {
            let previousStore = PortalStoreHolder.current
            let owningStore = PortalStore()
            let unrelatedStore = PortalStore()
            PortalStoreHolder.current = owningStore
            defer {
                owningStore.clear()
                unrelatedStore.clear()
                PortalStoreHolder.current = previousStore
            }

            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root:
                LayerRoot {
                    Box { EmptyView() }
                        .frame(width: 300, height: 200)
                } portals: {
                    PortalHost()
                }
            )

            // AppRuntime scopes the ambient per window. Recomposition can be
            // requested after that scope unwinds, so the host must not resolve
            // its entries from whichever store happens to be ambient later.
            PortalStoreHolder.current = unrelatedStore
            owningStore.register(id: "owning-window-popover",
                                 position: CGPoint(x: 30, y: 40),
                                 width: 120,
                                 content: AnyView(
                                    Box { EmptyView() }
                                        .frame(height: 60)
                                 ))
            _ = graph.recomposer.commitAll()
            graph.computeLayout(width: 300, height: 200)

            let snapshot = graph.layoutSnapshot()
            #expect(snapshot.first(where: {
                $0.debugName == "owning-window-popover"
            })?.absoluteFrame.origin == CGPoint(x: 30, y: 40))
        }
    }

    @Test("PortalHost does not participate in LayerRoot content flex")
    func portalHostDoesNotAffectContentFlex() {
        GlobalTestLock.locked {
            PortalStoreHolder.current.clear()
            PortalStoreHolder.current.register(id: "test-popover",
                                    position: CGPoint(x: 24, y: 32),
                                    width: 120,
                                    content: AnyView(
                                        Box { EmptyView() }
                                            .frame(height: 96)
                                            .debugName("portal-content")
                                    ))
            defer { PortalStoreHolder.current.clear() }

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
