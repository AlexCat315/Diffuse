import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Avatar identity and grouped layout", .serialized)
@MainActor
struct AvatarTests: GuavaUIComposeSerializedSuite {
    @Test("Unicode initials preserve graphemes, normalize whitespace and bound uppercase expansion")
    func unicodeInitials() {
        #expect(Avatar("Jason Lee").initials == "JL")
        #expect(Avatar("huacnlee").initials == "HU")
        #expect(Avatar("  李\t小龙\n").initials == "李小")
        #expect(Avatar("陈珊").initials == "陈珊")
        #expect(Avatar("e\u{301}mile Zola").initials == "E\u{301}Z")
        #expect(Avatar("👩🏽‍💻 coder").initials == "👩🏽‍💻C")
        #expect(Avatar("ßmith").initials == "SS")
        #expect(Avatar("\n \t").initials.isEmpty)
        #expect(AvatarIdentity.hueIndex("ÉZ") == AvatarIdentity.hueIndex("E\u{301}Z"))
    }
    @Test("All identity hues meet 4.5:1 contrast in both appearances")
    func paletteContrast() {
        func luminance(_ color: Color) -> Float {
            func channel(_ value: Float) -> Float { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
        }
        for dark in [true, false] { for hue in 0..<12 {
            let colors = AvatarIdentity.colors(hue: Float(hue) * 30, isDark: dark)
            let a = luminance(colors.foreground), b = luminance(colors.background)
            #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
        } }
    }
    @Test("Density, explicit size, outline and anonymous accessibility agree with actual geometry")
    func densityAndShapes() { GlobalTestLock.locked {
        for (size, diameter): (ControlSize, Float) in [(.mini, 16), (.small, 24), (.regular, 48), (.large, 80)] {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Avatar("Jason Lee").controlSize(size))
            graph.computeLayout(width: 200, height: 200)
            let node = descendants(graph.tree.root!).first { $0.accessibility?.role == .image }!
            #expect(Float(node.frame.width) == diameter && Float(node.frame.height) == diameter)
            #expect(node.cornerRadius == diameter / 2)
            #expect(node.accessibility?.label == "Jason Lee")
            #expect(!node.isFocusable)
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Avatar { $0.diameter = 100; $0.shape = .roundedRectangle(radius: 20); $0.borderWidth = 3 })
        graph.computeLayout(width: 200, height: 200)
        let node = descendants(graph.tree.root!).first { $0.accessibility?.role == .image }!
        #expect(node.frame.width == 100 && node.cornerRadius == 20)
        #expect(node.accessibility?.label == "Anonymous user")
    } }
    @Test("A group bounds its children, preserves stable IDs and puts earlier members above later ones")
    func groupGeometry() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let members = (0..<6).map { Avatar("Person \($0)", id: "p\($0)") }
        graph.install(root: AvatarGroup(members) { $0.limit = 3; $0.diameter = 48 })
        graph.computeLayout(width: 400, height: 200)
        let group = descendants(graph.tree.root!).first { $0.attachments["avatar.group.count"] != nil }!
        #expect(abs(Float(group.frame.width) - 167.2) <= 0.5)
        let avatars = descendants(group).filter { $0.attachments["avatar.initials"] != nil }
        #expect(avatars.count == 3)
        #expect(abs(Float(avatars[1].absoluteFrame.minX - avatars[0].absoluteFrame.minX) - 33.6) <= 0.5)
        let slots = group.children
        #expect(slots.count == 4)
        #expect(slots[0].zIndex > slots[1].zIndex)
        #expect(descendants(group).contains { $0.accessibility?.label == "3 more members" })
        graph.install(root: AvatarGroup(Array(members.reversed())) { $0.limit = 3; $0.diameter = 48 })
        graph.recomposer.commitAll(); graph.computeLayout(width: 400, height: 200)
        #expect(descendants(graph.tree.root!).contains { $0.accessibility?.label == "Person 5" })
        graph.install(root: EmptyView())
    } }
    @Test("Zero limits, hidden overflow and empty groups use their natural bounds")
    func groupBoundaries() {
        let count = AvatarGroupGeometry(total: 6, limit: 0, diameter: 48, overlap: 0.3, overflow: .count)
        #expect(count.visibleCount == 0 && count.width == 48)
        let hidden = AvatarGroupGeometry(total: 6, limit: 0, diameter: 48, overlap: 0.3, overflow: .hidden)
        #expect(hidden.itemCount == 0 && hidden.width == 0)
        let empty = AvatarGroupGeometry(total: 0, limit: 3, diameter: 48, overlap: 0.3, overflow: .count)
        #expect(empty.itemCount == 0 && empty.width == 0)
    }
    @Test("Rounded fill cropping never paints outside the container")
    func roundedFill() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Image(textureID: 7, width: 48, height: 48, sourcePixelSize: (200, 100), contentMode: .fill).cornerRadius(24))
        graph.computeLayout(width: 48, height: 48)
        let list = DrawList()
        descendants(graph.tree.root!).forEach { $0.draw?(list, .zero) }
        #expect(list.vertices.count > 4)
        #expect(list.vertices.allSatisfy { $0.posX >= 0 && $0.posX <= 48 && $0.posY >= 0 && $0.posY <= 48 })
        #expect(list.vertices.allSatisfy { $0.u >= 10.25 && $0.u <= 10.75 })
    } }
    private func descendants(_ node: Node) -> [Node] { [node] + node.children.flatMap(descendants) }
}
