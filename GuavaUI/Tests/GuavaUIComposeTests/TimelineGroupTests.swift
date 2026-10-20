import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Timeline groups, collapse and zoom", .serialized)
@MainActor
struct TimelineGroupTests: GuavaUIComposeSerializedSuite {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Proportional spacing follows elapsed time, clamps, and scales with zoom")
    func spacing() throws {
        let spacing = TimelineSpacing.proportional(pointsPerHour: 20, minimum: 4, maximum: 100)
        #expect(spacing.gap(from: start, to: start.addingTimeInterval(3_600), zoom: 1) == 20)
        #expect(spacing.gap(from: start, to: start.addingTimeInterval(60), zoom: 1) == 4)
        #expect(spacing.gap(from: start, to: start.addingTimeInterval(36_000), zoom: 1) == 100)
        #expect(spacing.gap(from: start, to: start.addingTimeInterval(3_600), zoom: 2) == 40)
        #expect(spacing.gap(from: nil, to: start, zoom: 1) == 0)
        #expect(TimelineSpacing.uniform.gap(from: start, to: start.addingTimeInterval(3_600), zoom: 1) == 0)
        var zoom = TimelineZoom(.constant(1)); zoom.range = 0.5...4
        #expect(zoom.clamped(10) == 4 && zoom.clamped(.nan) == 1)
    }

    private struct CollapseHarness: View {
        @State var collapsed: Set<String> = []
        let record: (Set<String>) -> Void
        var body: some View {
            Timeline(groups: [
                TimelineGroup("Today", events: [TimelineEvent("Build", id: "build"), TimelineEvent("Deploy", id: "deploy")]),
                TimelineGroup("Yesterday", events: [TimelineEvent("Review", id: "review")]),
            ]) { $0.collapsedGroups = Binding(get: { collapsed }, set: { collapsed = $0; record($0) }) }.frame(width: 480)
        }
    }

    private struct ZoomHarness: View {
        @State var factor: Float = 1
        let start: Date
        let record: (Float) -> Void
        var body: some View {
            Timeline(events: [
                TimelineEvent("First", id: "first", date: start),
                TimelineEvent("Second", id: "second", date: start.addingTimeInterval(3_600)),
            ]) {
                $0.spacing = .proportional(pointsPerHour: 40)
                $0.zoom = TimelineZoom(Binding(get: { factor }, set: { factor = $0; record($0) }))
            }.frame(width: 480)
        }
    }

    @Test("Group headers collapse their events and expose expanded state")
    func collapse() throws {
        try InteractiveScene.run(width: 500, height: 600) { scene in
            var collapsed: Set<String> = []
            scene.install(CollapseHarness(record: { collapsed = $0 }))
            let header = try #require(scene.first { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == "Today" })
            #expect(header.accessibility?.value == "2 events")
            #expect(header.accessibility?.state.isExpanded == true)
            #expect(scene.labelled("Deploy", role: .listItem) != nil)
            scene.click(header)
            #expect(collapsed == ["Today"])
            #expect(scene.labelled("Deploy", role: .listItem) == nil)
            #expect(scene.labelled("Review", role: .listItem) != nil)
            let reopened = try #require(scene.first { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == "Today" })
            #expect(reopened.accessibility?.state.isExpanded == false)
        }
    }

    @Test("Zoom buttons double and halve proportional gaps")
    func zoomControls() throws {
        try InteractiveScene.run(width: 500, height: 800) { scene in
            var factor: Float = 1
            scene.install(ZoomHarness(start: start, record: { factor = $0 }))
            func gap() throws -> CGFloat {
                let first = try #require(scene.labelled("First", role: .listItem))
                let second = try #require(scene.labelled("Second", role: .listItem))
                return second.absoluteFrame.minY - first.absoluteFrame.minY
            }
            let base = try gap()
            let zoomIn = try #require(scene.first { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == "Zoom in" })
            scene.click(zoomIn)
            #expect(factor == 2)
            #expect(abs(try gap() - base - 40) < 1)
            #expect(Timeline(events: [TimelineEvent("A")]).events.map(\.title) == ["A"])
        }
    }
}
