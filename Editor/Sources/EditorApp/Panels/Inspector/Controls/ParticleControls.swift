import EditorCore
import GuavaUICompose
import SceneRuntime

extension EditorInspectorFieldControlRegistry {
    /// Particle editors size their own rows: curves grow with their keyframes,
    /// stacks and sub-emitter lists with their entries.
    mutating func registerParticleControls() throws {
        try register(
            controlID: .particleCurve,
            fallback: ParticleCurve.linear,
            layout: .fullWidth,
            height: { binding, defaultHeight in
                if case .keyframes(let keyframes) = binding.wrappedValue {
                    return max(defaultHeight, ParticleCurveEditorLayout.rowHeight(keyframeCount: keyframes.count))
                }
                return max(defaultHeight, ParticleCurveEditorLayout.linearRowHeight)
            },
            control: { binding, _ in
                AnyView(InspectorPanel.InspectorParticleCurveValue(binding: binding))
            })

        try register(
            controlID: .particleSubEmitters,
            fallback: [ParticleSubEmitter](),
            layout: .fullWidth,
            height: { binding, defaultHeight in
                max(defaultHeight, ParticleSubEmitterEditorLayout.rowHeight(ruleCount: binding.wrappedValue.count))
            },
            control: { binding, _ in
                AnyView(InspectorPanel.InspectorParticleSubEmittersValue(binding: binding))
            })

        try register(
            controlID: .particleModuleStack,
            fallback: ParticleModuleStack(),
            layout: .fullWidth,
            height: { binding, defaultHeight in
                max(defaultHeight, ParticleModuleStackEditorLayout.rowHeight(stack: binding.wrappedValue))
            },
            control: { binding, _ in
                AnyView(InspectorPanel.InspectorParticleModuleStackValue(binding: binding))
            })
    }
}
