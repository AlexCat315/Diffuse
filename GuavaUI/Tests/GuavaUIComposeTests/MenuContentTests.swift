import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Menu rich rows, icons, links and submenu intent", .serialized)
@MainActor
struct MenuContentTests: GuavaUIComposeSerializedSuite {
    @Test("Icons share one lane, rich titles keep the accessible name and links announce as links")
    func rowContent() throws {
        try InteractiveScene.run { scene in
            var opened: [String] = []
            scene.install(LayerRoot {
                Menu([
                    .item(MenuItem(id: "copy", title: "Copy", content: MenuItemContent(icon: UIIcons.Action.check)) {}),
                    .item(MenuItem(id: "paste", title: "Paste") {}),
                    .item(MenuItem(id: "docs", title: "Documentation",
                                   content: MenuItemContent(richTitle: [RichTextRun("Read the "), RichTextRun("docs", traits: .bold)],
                                                            detail: "Opens in the browser", link: "https://example.com/docs")) {
                        opened.append("docs")
                    }),
                ], width: 260)
            })
            let copy = try #require(scene.labelled("Copy", role: .button))
            let paste = try #require(scene.labelled("Paste", role: .button))
            let docs = try #require(scene.labelled("Documentation"))
            #expect(docs.accessibility?.role == .link)
            #expect(docs.accessibility?.help == "https://example.com/docs")
            #expect(docs.accessibility?.value == "Opens in the browser")
            func title(_ row: Node, _ text: String) -> Node? {
                InteractiveScene.descendants(row).first { $0.accessibility?.label == text && $0 !== row }
            }
            let copyTitle = try #require(title(copy, "Copy")), pasteTitle = try #require(title(paste, "Paste"))
            #expect(abs(copyTitle.absoluteFrame.minX - pasteTitle.absoluteFrame.minX) < 0.5)
            // Rich title paragraphs do not take focus or selection from the row.
            #expect(!InteractiveScene.descendants(docs).contains { $0 !== docs && $0.isFocusable })
            scene.click(docs)
            #expect(opened == ["docs"])
        }
    }

    @Test("Type-ahead matches the plain title even when the row draws a rich title")
    func typeahead() throws {
        var typeahead = MenuTypeahead()
        var item = MenuRowPresentation(item: MenuItem(id: "docs", title: "Documentation",
            content: MenuItemContent(richTitle: [RichTextRun("Read the docs")])) {})
        item.isEnabled = true
        let other = MenuRowPresentation(item: MenuItem(id: "copy", title: "Copy") {})
        #expect(typeahead.destination("d", rows: [other, item], from: nil, time: 0) == AnyHashable("docs"))
        #expect(MenuItemContent(link: "").link == nil)
        #expect(MenuItemContent(richTitle: [RichTextRun("x", link: "y")]).richTitle.first?.link == nil)
    }

    @Test("Pointer travel toward an open submenu stays inside the safe triangle")
    func pointerIntent() throws {
        var intent = MenuPointerIntent()
        intent.submenuFrame = CGRect(x: 200, y: 0, width: 160, height: 200)
        intent.record(CGPoint(x: 150, y: 40))
        intent.record(CGPoint(x: 170, y: 60))
        #expect(intent.isHeadingToSubmenu)
        intent.record(CGPoint(x: 120, y: 90))
        #expect(!intent.isHeadingToSubmenu)
        var flipped = MenuPointerIntent()
        flipped.submenuFrame = CGRect(x: 0, y: 0, width: 100, height: 200)
        flipped.record(CGPoint(x: 160, y: 50)); flipped.record(CGPoint(x: 140, y: 70))
        #expect(flipped.isHeadingToSubmenu)
        #expect(MenuPointerIntent.triangle(.zero, CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10), contains: CGPoint(x: 2, y: 2)))
        #expect(!MenuPointerIntent.triangle(.zero, CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10), contains: CGPoint(x: 8, y: 8)))
    }

    @Test("Submenu icons reserve the lane in their parent level")
    func submenuIcon() throws {
        try InteractiveScene.run { scene in
            scene.install(LayerRoot {
                Menu([
                    .submenu(MenuSubmenu(id: "share", title: "Share", entries: [.item(MenuItem(title: "Mail") {})]) {
                        $0.icon = UIIcons.Action.externalLink
                    }),
                    .item(MenuItem(title: "Delete") {}),
                ], width: 240)
            })
            let share = try #require(scene.labelled("Share", role: .button))
            let delete = try #require(scene.labelled("Delete", role: .button))
            let images = { (row: Node) in InteractiveScene.descendants(row).filter { $0.viewTag?.contains(".Image") == true } }
            #expect(images(share).count >= 2) // icon + chevron
            #expect(images(delete).isEmpty)
        }
    }
}
