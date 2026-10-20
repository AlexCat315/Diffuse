import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Avatar presence and member list", .serialized)
@MainActor
struct AvatarPresenceTests: GuavaUIComposeSerializedSuite {
    @Test("Status sits on the outline at the logical bottom-trailing corner and is announced")
    func statusGeometryAndSemantics() throws {
        try InteractiveScene.run { scene in
            for rtl in [false, true] {
                scene.install(Box(direction: .row) {
                    Avatar("Jason Lee") { $0.diameter = 48; $0.status = .busy }
                }.layoutDirection(rtl ? .rtl : .ltr))
                let avatar = try #require(scene.first { $0.accessibility?.role == .image })
                let status = try #require(scene.first { $0.attachments["avatar.status"] != nil })
                #expect(avatar.accessibility?.value == "Busy")
                #expect(status.attachments["avatar.status"] as? AvatarStatus == .busy)
                let geometry = AvatarStatusGeometry(diameter: 48, shape: .circle)
                #expect(Float(status.frame.width) == geometry.size)
                // The indicator center lies on the circle's 45° diagonal.
                let frame = status.absoluteFrame, box = avatar.absoluteFrame
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let distance = hypot(center.x - box.midX, center.y - box.midY)
                #expect(abs(distance - 24) < 1.5)
                #expect(rtl ? center.x < box.midX : center.x > box.midX)
                #expect(center.y > box.midY)
            }
        }
    }

    @Test("Status labels can be overridden and every status has a distinct shape")
    func statusLabels() throws {
        #expect(Avatar("A") { $0.status = .away; $0.statusLabel = "In a meeting" }.statusText == "In a meeting")
        #expect(Avatar("A").statusText.isEmpty)
        #expect(Set(AvatarStatus.allCases.map(\.label)).count == 4)
        let square = AvatarStatusGeometry(diameter: 48, shape: .square)
        #expect(square.inset == -square.size / 2)
    }

    @Test("The overflow marker opens the member list, which reports selection and closes")
    func memberList() throws {
        try InteractiveScene.run { scene in
            var selected: String?
            let members = (0..<5).map { Avatar("Person \($0)", id: "p\($0)") { $0.status = .online } }
            scene.install(LayerRoot {
                AvatarGroup(members) {
                    $0.limit = 2; $0.diameter = 32
                    var list = AvatarMemberList(); list.scope = .remaining
                    list.onSelect = { selected = $0.id }
                    $0.memberList = list
                }
            })
            let trigger = try #require(scene.first { $0.attachments[ButtonHost.markerKey] != nil })
            #expect(trigger.accessibility?.label == "3 more members")
            scene.click(trigger)
            let rows = scene.all { $0.accessibility?.role == .button && $0.accessibility?.label.hasPrefix("Person") == true }
            #expect(rows.map { $0.accessibility?.label } == ["Person 2", "Person 3", "Person 4"])
            #expect(rows.first?.accessibility?.value == "Online")
            scene.click(rows[1])
            #expect(selected == "p3")
            let remaining = scene.all { $0.accessibility?.role == .button && $0.accessibility?.label.hasPrefix("Person") == true }
            #expect(remaining.isEmpty)
        }
    }

    @Test("Without a member list the marker stays a non-interactive image")
    func staticMarker() {
        InteractiveScene.run { scene in
            scene.install(AvatarGroup((0..<4).map { Avatar("P\($0)") }) { $0.limit = 1; $0.diameter = 32 })
            #expect(scene.first { $0.attachments[ButtonHost.markerKey] != nil } == nil)
            #expect(scene.labelled("3 more members", role: .image) != nil)
        }
    }
}
