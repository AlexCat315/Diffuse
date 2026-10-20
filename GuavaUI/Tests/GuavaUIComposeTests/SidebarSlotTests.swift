import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Sidebar inline view slots", .serialized)
@MainActor
struct SidebarSlotTests: GuavaUIComposeSerializedSuite {
    @Test("Leading and trailing slots render inside the row and stay out of the accessible name")
    func decorativeSlots() throws {
        try InteractiveScene.run(width: 300, height: 400) { scene in
            var selection: String? = "inbox"
            scene.install(Sidebar(selection: Binding(get: { selection }, set: { selection = $0 }), sections: [
                SidebarSection("main", items: [
                    SidebarItem("inbox", "Inbox") {
                        $0.slots.leading = AnyView(Box {}.frame(width: 10, height: 10).debugName("lead-dot"))
                        $0.slots.trailing = AnyView(Text("12").debugName("trail-text"))
                    },
                    SidebarItem("plain", "Plain"),
                ])
            ]).frame(width: 280, height: 380))
            let row = try #require(scene.named("sidebar-item-inbox"))
            let lead = try #require(scene.named("lead-dot")), trail = try #require(scene.named("sidebar-trailing-inbox"))
            #expect(InteractiveScene.descendants(row).contains { $0 === lead })
            #expect(InteractiveScene.descendants(row).contains { $0 === trail })
            #expect(lead.absoluteFrame.maxX <= trail.absoluteFrame.minX)
            #expect(row.accessibility?.label == "Inbox")
            // The plain row shares the leading lane opened by the slot.
            let plainTitle = try #require(scene.named("sidebar-title-plain"))
            let inboxTitle = try #require(scene.named("sidebar-title-inbox"))
            #expect(abs(plainTitle.absoluteFrame.minX - inboxTitle.absoluteFrame.minX) < 0.5)
        }
    }

    @Test("An accessory is a separate interactive target that reserves width for the title")
    func interactiveAccessory() throws {
        try InteractiveScene.run(width: 300, height: 400) { scene in
            var selection: String? = nil
            var toggles = 0
            scene.install(Sidebar(selection: Binding(get: { selection }, set: { selection = $0 }), sections: [
                SidebarSection("main", items: [
                    SidebarItem("layer", "A very long layer name that would run under the toggle") {
                        $0.slots.accessory = AnyView(Button(icon: .resource(UIIcons.Action.check), size: 12) { toggles += 1 }
                            .accessibilityLabel("Toggle visibility"))
                        $0.slots.accessoryWidth = 40
                        $0.contextMenu = [.item(MenuItem(id: "rename", title: "Rename") {})]
                    },
                ])
            ]).frame(width: 280, height: 380))
            let accessory = try #require(scene.named("sidebar-accessory-layer"))
            let actions = try #require(scene.named("sidebar-actions-layer"))
            let title = try #require(scene.named("sidebar-title-layer"))
            #expect(abs(Float(accessory.frame.width) - 40) < 0.5)
            #expect(accessory.absoluteFrame.maxX <= actions.absoluteFrame.minX + 0.5)
            #expect(title.absoluteFrame.maxX <= accessory.absoluteFrame.minX + 0.5)
            let button = try #require(InteractiveScene.descendants(accessory).first { $0.attachments[ButtonHost.markerKey] != nil })
            scene.click(button)
            #expect(toggles == 1)
            #expect(selection == nil)
        }
    }
}
