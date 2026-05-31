import XCTest
@testable import GuavaUIApp
import GuavaUICompose

final class PanelRegistryTests: XCTestCase {
    func testRegisterAndResolve() {
        let registry = PanelRegistry()
        XCTAssertTrue(registry.isEmpty)

        registry.register(PanelDescriptor(id: "hierarchy", title: "Scene") {
            EmptyView()
        })
        registry.register(PanelDescriptor(id: "inspector", title: "Inspector") {
            EmptyView()
        })

        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.ids, [PanelID("hierarchy"), PanelID("inspector")])
        XCTAssertEqual(registry.descriptor(for: "hierarchy")?.title, "Scene")
        XCTAssertNil(registry.descriptor(for: "missing"))
    }

    func testRegisterOverwriteKeepsOrder() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "a", title: "A") { EmptyView() },
            PanelDescriptor(id: "b", title: "B") { EmptyView() },
            PanelDescriptor(id: "c", title: "C") { EmptyView() },
        ])

        registry.register(PanelDescriptor(id: "b", title: "B'") { EmptyView() })

        XCTAssertEqual(registry.ids, [PanelID("a"), PanelID("b"), PanelID("c")])
        XCTAssertEqual(registry.descriptor(for: "b")?.title, "B'")
    }

    func testUpdateDescriptorKeepsFactoryAndOrder() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "a", title: "A") { Text("A") },
            PanelDescriptor(id: "b", title: "B") { Text("B") },
        ])

        registry.updateDescriptor(id: "b") { descriptor in
            descriptor.title = "Localized B"
        }

        XCTAssertEqual(registry.ids, [PanelID("a"), PanelID("b")])
        XCTAssertEqual(registry.descriptor(for: "b")?.title, "Localized B")
        _ = registry.make("b")
    }

    func testUnregister() {
        let registry = PanelRegistry([
            PanelDescriptor(id: "a", title: "A") { EmptyView() },
            PanelDescriptor(id: "b", title: "B") { EmptyView() },
        ])

        registry.unregister(id: "a")

        XCTAssertEqual(registry.ids, [PanelID("b")])
        XCTAssertNil(registry.descriptor(for: "a"))
    }

    func testMakeReturnsEmptyForUnknownID() {
        let registry = PanelRegistry()
        // 不应该抛或崩溃；缺失的 tab userKey 在 Workspace 里返回 EmptyView，
        // 让 dock 残留 tab 的失败模式是“空白”而不是崩溃。
        _ = registry.make("nope")
    }
}
