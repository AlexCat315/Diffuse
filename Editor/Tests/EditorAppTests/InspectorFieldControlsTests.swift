import EditorCore
import GuavaUICompose
import SceneRuntime
import Testing
@testable import EditorApp

@Suite("Inspector field control registry")
struct InspectorFieldControlTests {
    @Test("built-in compound controls resolve by control ID and declare their row metrics")
    func builtInControls() throws {
        let registry = EditorInspectorFieldControlRegistry.builtIn
        #expect(Set(registry.controlIDs) == [
            .colliderShapeInstances, .particleCurve, .particleSubEmitters, .particleModuleStack, .entityReference
        ])

        let curve = EditorInspectorFieldValue.particleCurve(.constant(.linear))
        #expect(curve.controlID == .particleCurve)
        #expect(registry.view(for: curve, context: .empty) != nil)
        let metrics = try #require(registry.metrics(for: curve))
        #expect(metrics.layout == .fullWidth)
        #expect(metrics.sizing == .fixed)
        let binding = try #require(curve.erasedBinding)
        #expect(metrics.height(binding, 28) == max(28, ParticleCurveEditorLayout.linearRowHeight))

        let shapes = EditorInspectorFieldValue.colliderShapeInstances(.constant([]))
        #expect(registry.view(for: shapes, context: .empty) != nil)
        #expect(try #require(registry.metrics(for: shapes)).sizing == .intrinsic)

        let reference = EditorInspectorFieldValue.entityReference(.constant(7), options: [])
        #expect(reference.entityOptions?.isEmpty == true)
        #expect(registry.view(for: reference, context: .empty) != nil)
        #expect(registry.view(for: .number(.constant(1)), context: .empty) == nil)
        #expect(registry.metrics(for: .number(.constant(1))) == nil)
    }

    @Test("an erased binding writes the component value back through its typed control")
    func erasedBindingRoundTrip() throws {
        var stored = ParticleCurve.linear
        let field = EditorInspectorFieldValue.particleCurve(Binding(get: { stored }, set: { stored = $0 }))
        let typed = try #require(field.erasedBinding).typed(fallback: ParticleCurve.linear)
        typed.wrappedValue = .easeOut
        #expect(stored == .easeOut)
    }

    @Test("controls reject duplicates and stay replaceable after an explicit removal")
    func registrationLifecycle() throws {
        var registry = EditorInspectorFieldControlRegistry()
        #expect(registry.view(for: .particleCurve(.constant(.linear)), context: .empty) == nil)
        try registry.registerParticleControls()
        #expect(registry.view(for: .particleCurve(.constant(.linear)), context: .empty) != nil)
        #expect(throws: EditorInspectorFieldControlError.duplicateControl(.particleCurve)) {
            try registry.register(controlID: .particleCurve, fallback: ParticleCurve.linear) { _, _ in
                AnyView(Text(L("Replacement")))
            }
        }
        let removed = registry.remove(controlID: .particleCurve)
        #expect(removed)
        #expect(registry.view(for: .particleCurve(.constant(.linear)), context: .empty) == nil)
    }
}
