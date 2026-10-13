import GuavaUIWorkspace
import XCTest
import GuavaUICompose

final class PanelRegistryTests: XCTestCase {
    func testRegisterAndResolve() {
        let registry = WorkspacePanelRegistry()
        XCTAssertTrue(registry.isEmpty)

        registry.register(WorkspacePanelDescriptor(id: "hierarchy", title: "Scene", defaultSlot: .center, configure: { $0.isCollapsible = false }) {
            EmptyView()
        })
        registry.register(WorkspacePanelDescriptor(id: "inspector", title: "Inspector", defaultSlot: .center, configure: { $0.isCollapsible = false }) {
            EmptyView()
        })

        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.ids, [WorkspacePanelID("hierarchy"), WorkspacePanelID("inspector")])
        XCTAssertEqual(registry.descriptor(for: "hierarchy")?.panel.title, "Scene")
        XCTAssertNil(registry.descriptor(for: "missing"))
    }

    func testRegisterOverwriteKeepsOrder() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "a", title: "A", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
            WorkspacePanelDescriptor(id: "b", title: "B", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
            WorkspacePanelDescriptor(id: "c", title: "C", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
        ])

        registry.register(WorkspacePanelDescriptor(id: "b", title: "B'", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() })

        XCTAssertEqual(registry.ids, [WorkspacePanelID("a"), WorkspacePanelID("b"), WorkspacePanelID("c")])
        XCTAssertEqual(registry.descriptor(for: "b")?.panel.title, "B'")
    }

    func testUpdateDescriptorKeepsFactoryAndOrder() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "a", title: "A", defaultSlot: .center, configure: { $0.isCollapsible = false }) { Text("A") },
            WorkspacePanelDescriptor(id: "b", title: "B", defaultSlot: .center, configure: { $0.isCollapsible = false }) { Text("B") },
        ])

        registry.updateDescriptor(id: "b") { descriptor in
            descriptor.panel.title = "Localized B"
        }

        XCTAssertEqual(registry.ids, [WorkspacePanelID("a"), WorkspacePanelID("b")])
        XCTAssertEqual(registry.descriptor(for: "b")?.panel.title, "Localized B")
        _ = registry.make("b")
    }

    func testUnregister() {
        let registry = WorkspacePanelRegistry([
            WorkspacePanelDescriptor(id: "a", title: "A", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
            WorkspacePanelDescriptor(id: "b", title: "B", defaultSlot: .center, configure: { $0.isCollapsible = false }) { EmptyView() },
        ])

        registry.unregister(id: "a")

        XCTAssertEqual(registry.ids, [WorkspacePanelID("b")])
        XCTAssertNil(registry.descriptor(for: "a"))
    }

    func testMakeReturnsEmptyForUnknownID() {
        let registry = WorkspacePanelRegistry()
        // 不应该抛或崩溃；缺失的 tab userKey 在 Workspace 里返回 EmptyView，
        // 让 dock 残留 tab 的失败模式是“空白”而不是崩溃。
        _ = registry.make("nope")
    }
}
