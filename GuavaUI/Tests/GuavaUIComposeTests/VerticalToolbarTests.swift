import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Vertical toolbar", .serialized)
@MainActor
struct VerticalToolbarTests: GuavaUIComposeSerializedSuite {
    @Test("Commands stack vertically, Up/Down move focus and the divider sits on the trailing edge")
    func layoutAndKeys() throws {
        try InteractiveScene.run(width: 400, height: 500) { scene in
            scene.install(Toolbar(configure: { $0.axis = .vertical; $0.divider = .trailing; $0.label = "Tools" }) {
                Button(icon: .resource(UIIcons.Action.plus), size: 14) {}.accessibilityLabel("Add")
                ToolbarSeparator()
                ToolbarGroup(isBordered: true, label: "Edit") {
                    Button(icon: .resource(UIIcons.Action.minus), size: 14) {}.accessibilityLabel("Remove")
                    Button(icon: .resource(UIIcons.Action.check), size: 14) {}.accessibilityLabel("Confirm")
                }
            }.frame(height: 400))
            let toolbar = try #require(scene.first { $0.accessibility?.role == .toolbar })
            #expect(toolbar.attachments["toolbar.axis"] as? ToolbarAxis == .vertical)
            let buttons = ["Add", "Remove", "Confirm"].map { label in
                scene.first { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == label }!
            }
            #expect(buttons[0].absoluteFrame.maxY <= buttons[1].absoluteFrame.minY)
            #expect(buttons[1].absoluteFrame.maxY <= buttons[2].absoluteFrame.minY)
            #expect(abs(buttons[0].absoluteFrame.midX - buttons[2].absoluteFrame.midX) < 1)
            scene.focus.focus(buttons[0])
            scene.key(Scancode.arrowDown)
            #expect(scene.focus.focused === buttons[1])
            scene.key(Scancode.end)
            #expect(scene.focus.focused === buttons[2])
            scene.key(Scancode.arrowRight)
            #expect(scene.focus.focused === buttons[2])
            scene.key(Scancode.arrowUp)
            #expect(scene.focus.focused === buttons[1])
        }
    }

    @Test("Command lists overflow by height into a menu opened beside the bar")
    func verticalOverflow() throws {
        try InteractiveScene.run(width: 400, height: 300) { scene in
            let items = (0..<12).map { index in
                ToolbarItem(MenuItem(id: "c\(index)", title: "Command \(index)") {}, icon: .resource(UIIcons.Action.plus))
            }
            scene.install(LayerRoot { Toolbar(items: items) { $0.axis = .vertical }.frame(height: 220) })
            let more = try #require(scene.labelled("More actions"))
            let visible = scene.all { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label.hasPrefix("Command") == true
                && $0.acceptsSubtreeInput }
            #expect(!visible.isEmpty && visible.count < 12)
            #expect(visible.allSatisfy { $0.absoluteFrame.maxY <= more.absoluteFrame.minY + 1 })
            scene.click(more)
            let menuRows = scene.all { $0.attachments["__menu_item_id"] != nil }
            #expect(!menuRows.isEmpty && menuRows.count == 12 - visible.count)
        }
    }

}
