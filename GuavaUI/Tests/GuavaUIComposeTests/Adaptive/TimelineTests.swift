import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Adaptive timeline", .serialized)
@MainActor
struct TimelineTests: GuavaUIComposeSerializedSuite {
    private nonisolated static let longTitle = "Shaders compiled for the international collaboration workspace 👩🏽‍💻"
    private nonisolated static let longTime = "09:12 · Build worker in Shanghai · 2026-10-18"
    private nonisolated static let detail = "All target profiles are available for review. 已完成所有目标的着色器编译，可以开始协作。"
    private final class Harness: View {
        @State var width: Float = 390
        @State var scale: Float = 1
        @State var dark = false
        @State var rtl = false
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var events = [TimelineEvent("Build started", id: "started", trailing: "09:12", tone: .info),
            TimelineEvent(TimelineTests.longTitle, id: "compiled", detail: TimelineTests.detail,
                          trailing: TimelineTests.longTime, tone: .success)]
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = 1280; surface.viewport.height = 2000; surface.input = input
            return Box(direction: .column, alignItems: .flexStart, spacing: 12) {
                Button("Retained action") {}.accessibilityLabel("Retained action")
                Timeline(events: events).frame(width: width)
            }.frame(width: 1280, height: 2000).surfaceEnvironment(surface)
                .textScaler(.init(scale)).appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr)
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func text(_ value: String, in root: Node?) throws -> Node {
        try #require(nodes(root).first { $0.layoutNode?.textInputs?.text == value })
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 2000) }
        NodeRenderer().render(root: graph.tree.root!, into: DrawList())
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            try context.withCurrent {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h); settle(graph)
                defer { graph.install(root: EmptyView()) }
                try work(h, graph, context)
            }
        }
    }

    @Test("Container reflow preserves events and focus across width, text scale, input, themes and RTL")
    func matrix() throws {
        try scene { h, graph, context in
            let shortTitle = try text("Build started", in: graph.tree.root)
            let longTitle = try text(Self.longTitle, in: graph.tree.root)
            let action = try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == "Retained action" })
            context.focusChain.focus(action)
            for width: Float in [390, 720, 1280, 390] { for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] { for rtl in [false, true] {
                        h.width = width; h.scale = scale; h.input = input; h.dark = dark; h.rtl = rtl; settle(graph)
                        #expect(try text("Build started", in: graph.tree.root) === shortTitle)
                        #expect(try text(Self.longTitle, in: graph.tree.root) === longTitle)
                        #expect(context.focusChain.focused === action)
                        let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
                        #expect(rows.count == 2)
                        #expect(rows[1].accessibility?.label == Self.longTitle && rows[1].accessibility?.value == Self.longTime)
                        #expect(rows[1].accessibility?.help == Self.detail)
                        #expect(rows[1].absoluteFrame.minY >= rows[0].absoluteFrame.maxY)
                        for row in rows {
                            for leaf in nodes(row) where leaf.layoutNode?.textInputs != nil {
                                #expect(leaf.absoluteFrame.minX >= row.absoluteFrame.minX - 1)
                                #expect(leaf.absoluteFrame.maxX <= row.absoluteFrame.maxX + 1)
                                #expect(leaf.absoluteFrame.maxY <= row.absoluteFrame.maxY + 1)
                                #expect((leaf.layoutNode?.textMeasure?.result.totalWidth ?? 0) <= Float(leaf.frame.width) + 1)
                            }
                        }
                        let time = try text("09:12", in: rows[0])
                        if width < 600 { #expect(time.absoluteFrame.minY >= shortTitle.absoluteFrame.maxY) }
                        else {
                            #expect(abs(time.absoluteFrame.midY - shortTitle.absoluteFrame.midY) < 1)
                            if rtl { #expect(time.absoluteFrame.maxX <= shortTitle.absoluteFrame.minX) }
                            else { #expect(time.absoluteFrame.minX >= shortTitle.absoluteFrame.maxX) }
                        }
                        if width == 390 { #expect((longTitle.layoutNode?.textMeasure?.result.lines.count ?? 0) > 1) }
                        if width == 720 && scale == 2 {
                            #expect(try text(Self.longTime, in: rows[1]).absoluteFrame.minY >= longTitle.absoluteFrame.maxY)
                        }
                        #expect(longTitle.foregroundColor == (dark ? Theme.defaultDark : .defaultLight).colors.onSurface)
                        #expect(!graph.recomposer.hasPending)
                    } }
                }
            } }
        }
    }

    @Test("Identified events retain their nodes on reorder and expose updated timestamps to the AI query")
    func reorderAndDiagnostics() throws {
        try scene { h, graph, _ in
            let title = try text(Self.longTitle, in: graph.tree.root)
            h.events.reverse(); h.events[0].trailing = "Updated · 10:04"; settle(graph)
            #expect(try text(Self.longTitle, in: graph.tree.root) === title)
            let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
            #expect(rows.first?.accessibility?.label == Self.longTitle)
            #expect(rows.first?.accessibility?.value == "Updated · 10:04")
            let diagnostics = UIDiagnostics(tree: graph.tree)
            let response = diagnostics.handleReadRequest(.init(type: "diagnostics.call", payload: .object([
                "name": .string("query_ui_nodes"), "arguments": .object([
                    "role": .string("listItem"), "text": .string("Updated · 10:04"), "visible_only": .bool(true)
                ])
            ])))
            #expect(response.type == "diagnostics.call.ok")
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
            #expect((json["data"] as? [String: Any])?["total"] as? Int == 1)
            h.events.removeAll(); settle(graph)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.role == .listItem })
            #expect(!graph.recomposer.hasPending)
        }
    }

    @Test("Missing metadata adds no blank line and very long metadata wraps inside the content")
    func metadataEdges() throws {
        try scene { h, graph, _ in
            h.width = 160; h.scale = 2; h.events = [
                TimelineEvent("Ready", id: "ready"),
                TimelineEvent("Review", id: "review", trailing: Self.longTime)
            ]; settle(graph)
            let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
            let ready = try text("Ready", in: rows[0])
            #expect(abs(rows[0].frame.height - ready.frame.height - CGFloat(ready.theme.spacing.sm)) < 1)
            let review = try text("Review", in: rows[1]), meta = try text(Self.longTime, in: rows[1])
            #expect(meta.absoluteFrame.minY >= review.absoluteFrame.maxY)
            #expect((meta.layoutNode?.textMeasure?.result.lines.count ?? 0) > 1)
            #expect(meta.absoluteFrame.maxX <= rows[1].absoluteFrame.maxX + 1)
            #expect(meta.absoluteFrame.maxY <= rows[1].absoluteFrame.maxY + 1)
        }
    }
}
