import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Numeric locales", .serialized)
@MainActor
struct NumericLocaleTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Localized decimals, digits and signs round-trip, while grouping and partial parses are rejected")
    func formats() {
        for identifier in ["en_US_POSIX", "de_DE", "fr_FR", "ar_EG", "sv_SE"] {
            let format = NumericTextFormat(locale: Locale(identifier: identifier), decimals: 2)
            for value: Float in [-1234.5, -0.5, 0, 1.25, 9999.75] {
                #expect(format.parse(format.format(value)) == value)
            }
            #expect(format.format(-0.00001) == format.format(0))
            #expect(format.parse("NaN") == nil && format.parse("infinity") == nil)
        }
        let comma = NumericTextFormat(locale: Locale(identifier: "de_DE"), decimals: 2)
        #expect(comma.format(1234.5) == "1234,5")
        #expect(comma.parse("12,5e2") == 1250)
        for invalid in ["1.234", "12,5suffix", "1,2,3", "", "1 234", "1e999"] {
            #expect(comma.parse(invalid) == nil)
        }
    }

    @Test("A localized field commits, restores invalid drafts and uses the locale while stepping")
    func editing() throws {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            try context.withCurrent {
                var value: Float = 1.25
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: NumberField(value: Binding(get: { value }, set: { value = $0 }),
                    step: 0.25, locale: Locale(identifier: "de_DE")).frame(width: 220))
                let field = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .textField && $0.isFocusable })
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 200) } }
                func key(_ code: UInt32, modifiers: KeyModifiers = []) {
                    input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
                }
                context.focusChain.focus(field); settle()
                key(Scancode.a, modifiers: [.gui]); input.dispatch(.textInput("12,75")); key(Scancode.return); settle()
                #expect(value == 12.75 && field.resolvedAccessibilityValue == "12,75")
                key(Scancode.a, modifiers: [.gui]); input.dispatch(.textInput("12,75suffix")); key(Scancode.return); settle()
                #expect(value == 12.75 && field.resolvedAccessibilityValue == "12,75")
                key(Scancode.arrowUp); settle()
                #expect(value == 13 && field.resolvedAccessibilityValue == "13")
                graph.install(root: EmptyView())
            }
        }
    }

    @Test("Vector fields share localized formatting and grow their chrome for touch and text scaling")
    func vectors() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for width: Float in [390, 720, 1280] {
                for scale: Float in [1, 2] {
                    let context = PlatformInputContext()
                    try context.withCurrent {
                        var surface = UIEnvironment(); surface.viewport.width = width
                        surface.input = width == 1280 ? [.pointer, .keyboard] : [.touch, .keyboard]
                        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                        graph.install(root: Vec3Field(x: .constant(1.25), y: .constant(2.5), z: .constant(3.75),
                            locale: Locale(identifier: "de_DE")).frame(width: 260)
                            .surfaceEnvironment(surface).textScaler(.init(scale)))
                        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 300) }
                        let fields = nodes(graph.tree.root!).filter { $0.accessibility?.role == .textField && $0.isFocusable }
                        #expect(fields.count == 3)
                        #expect(fields.map(\.resolvedAccessibilityValue) == ["1,25", "2,5", "3,75"])
                        let minimum: CGFloat = max(CGFloat(28 * scale), width == 1280 ? 0 : 44)
                        #expect(fields.allSatisfy { $0.frame.height >= minimum }, "width=\(width) scale=\(scale) minimum=\(minimum) frames=\(fields.map(\.frame))")
                        graph.install(root: EmptyView())
                    }
                }
            }
        }
    }
}
