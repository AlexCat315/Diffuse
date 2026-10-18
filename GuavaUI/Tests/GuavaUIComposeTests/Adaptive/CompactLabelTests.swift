import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Constrained content labels", .serialized)
@MainActor
struct CompactLabelTests: GuavaUIComposeSerializedSuite {
    private let title = "Workspace collaboration reviewers awaiting approval"
    private let key = "Open workspace command palette"
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func accessible(_ elements: [AccessibilityElement]) -> [AccessibilityElement] {
        elements.flatMap { [$0] + accessible($0.children) }
    }

    @Test("Long labels wrap without losing text or controls, and decorative caps announce only once")
    func matrix() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    for rtl in [false, true] {
                        for theme in [Theme.defaultLight, Theme.defaultDark] {
                            let context = PlatformInputContext()
                            try context.withCurrent {
                                var surface = UIEnvironment(); surface.viewport.width = width
                                surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                                graph.install(root: Box(direction: .column, alignItems: .stretch, spacing: 16) {
                                    Badge(title, tone: .warning) { $0.showsDot = true }.debugName("long-badge")
                                    Tag(title) { $0.icon = UIIcons.File.folder; $0.onRemove = {} }.debugName("long-tag")
                                    KeyCap(["⌘", "⇧", key]).debugName("long-caps")
                                    FieldLabel(title) { $0.targetID = "name" }
                                    TextField("Name", text: .constant("")).accessibility { $0.identifier = "name" }
                                }.frame(width: 220).surfaceEnvironment(surface).textScaler(.init(scale))
                                    .layoutDirection(rtl ? .rtl : .ltr).theme(theme))
                                defer { graph.install(root: EmptyView()) }
                                for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 2000) }
                                let all = nodes(graph.tree.root!)
                                let titleNodes = all.filter { $0.layoutNode?.textInputs?.text == title }
                                #expect(titleNodes.count == 3)
                                for text in titleNodes {
                                    #expect(!text.clipsToBounds && text.frame.width > 0)
                                    #expect(text.layoutNode?.textMeasure?.key.text == title)
                                    #expect((text.layoutNode?.textMeasure?.result.lines.count ?? 0) > 1)
                                    #expect(text.absoluteFrame.minX >= 0 && text.absoluteFrame.maxX <= 220)
                                }
                                let remove = try #require(all.first { $0.accessibility?.label == "Remove \(title)" && $0.accessibility?.role == .button })
                                if width != 1280 { #expect(remove.frame.width >= 44 && remove.frame.height >= 44) }
                                #expect(remove.absoluteFrame.minX >= 0 && remove.absoluteFrame.maxX <= 220)
                                let caps = try #require(graph.layoutSnapshot().first { $0.debugName == "long-caps" })
                                for text in all.filter({ ["⌘", "⇧", key].contains($0.layoutNode?.textInputs?.text ?? "") }) {
                                    #expect(text.absoluteFrame.minX >= caps.absoluteFrame.minX)
                                    #expect(text.absoluteFrame.maxX <= caps.absoluteFrame.maxX)
                                }
                                let spoken = accessible(AccessibilityTree.snapshot(root: graph.tree.root!))
                                #expect(spoken.filter { $0.semantics.label == "Command Shift \(key)" }.count == 1)
                                #expect(!spoken.contains { $0.semantics.label == "⌘" || $0.semantics.label == "⇧" })
                                let label = try #require(all.first { $0.accessibility?.role == .button && $0.accessibility?.label == title })
                                let labelText = try #require(nodes(label).first { $0.layoutNode?.textInputs?.text == title })
                                if rtl { #expect(abs(labelText.absoluteFrame.maxX - label.absoluteFrame.maxX) < 0.5) }
                                else { #expect(abs(labelText.absoluteFrame.minX - label.absoluteFrame.minX) < 0.5) }
                                let target = try #require(all.first { $0.accessibility?.identifier == "name" })
                                label.accessibilityActions.activate?()
                                #expect(context.focusChain.focused === target)
                            }
                        }
                    }
                }
            }
        }
    }
}
