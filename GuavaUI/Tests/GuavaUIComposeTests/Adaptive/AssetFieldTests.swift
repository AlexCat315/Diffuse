import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive asset references", .serialized)
@MainActor
struct AssetFieldAdaptiveTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        static let title = "Environment reflection texture for the shared workspace"
        @State var value: AssetRef? = .init(id: "initial", name: title, subtitle: "High dynamic range environment", kind: "texture")
        var enabled = true
        var body: some View {
            AssetRefField(value: $value, acceptedKinds: ["texture"], pickerOptions: [
                AssetRef(id: "texture", name: Self.title, subtitle: "High dynamic range environment", kind: "texture"),
                AssetRef(id: "forbidden", name: "Forbidden material", kind: "material")
            ], isEnabled: enabled).frame(width: 220)
        }
    }
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func button(_ title: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .button && $0.accessibility?.label == title })
    }

    @Test("Touch actions fit the field; the picker respects accepted kinds and preserves full values")
    func matrix() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    for rtl in [false, true] {
                        for theme in [Theme.defaultLight, Theme.defaultDark] {
                            let context = PlatformInputContext(), store = PortalStore()
                            context.addScopedAmbient(PortalStoreAmbient(store))
                            try context.withCurrent {
                                var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = 820
                                surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                                let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                                graph.install(root: LayerRoot { harness }.surfaceEnvironment(surface).textScaler(.init(scale))
                                    .layoutDirection(rtl ? .rtl : .ltr).theme(theme).reducedMotion())
                                defer { graph.install(root: EmptyView()) }
                                func settle() { for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 820) } }
                                settle()
                                let field = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .group && $0.accessibility?.label == Harness.title })
                                #expect(field.frame.width == 220)
                                #expect(field.frame.height >= CGFloat(max(32 * scale, width == 1280 ? 0 : 52)))
                                #expect(field.accessibility?.value.contains("texture") == true)
                                for action in [try button("Clear asset", in: graph), try button("Choose asset", in: graph)] {
                                    #expect(field.absoluteFrame.contains(action.absoluteFrame))
                                    if width != 1280 { #expect(action.frame.width >= 44 && action.frame.height >= 44) }
                                }
                                try button("Choose asset", in: graph).accessibilityActions.activate?(); settle()
                                #expect(!nodes(graph.tree.root!).contains { $0.accessibility?.label == "Forbidden material" })
                                let option = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .button && $0.accessibility?.label.hasPrefix(Harness.title) == true })
                                #expect(option.absoluteFrame.minX >= 0 && option.absoluteFrame.maxX <= CGFloat(width))
                                option.accessibilityActions.activate?(); settle()
                                #expect(harness.value?.id == "texture")
                                try button("Clear asset", in: graph).accessibilityActions.activate?(); settle()
                                #expect(harness.value == nil)
                                #expect(try button("Choose asset", in: graph).accessibility?.role == .button)
                                #expect(!nodes(graph.tree.root!).contains { $0.accessibility?.role == .button && $0.accessibility?.label == "Clear asset" })
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Disabled asset controls expose no activation path")
    func disabled() throws {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            try context.withCurrent {
                let harness = Harness(enabled: false), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                defer { graph.install(root: EmptyView()) }
                for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 200) }
                for action in [try button("Clear asset", in: graph), try button("Choose asset", in: graph)] {
                    #expect(action.accessibility?.state.isEnabled == false && action.accessibilityActions.activate == nil)
                }
                #expect(harness.value?.id == "initial")
            }
        }
    }
}
