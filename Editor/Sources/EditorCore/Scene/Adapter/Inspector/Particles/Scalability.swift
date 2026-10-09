import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func particleScalabilitySection() -> EditorInspectorSection {
        let state = scene.resource(ParticleScalabilityStateResource.self) ?? .default
        return EditorInspectorSection(
            id: "particle-scalability",
            title: L("Particle Scalability"),
            fields: [
                EditorInspectorField(id: "particle-scale-emission", label: L("Emission Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.emissionScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-burst", label: L("Burst Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.burstScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-distance", label: L("Distance Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.distanceEmissionScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-live-cap", label: L("Live Cap Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.maxLiveParticleScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-enabled", label: L("Auto Scale"),
                                     value: .bool(particleScalabilityPolicyEnabledBinding())),
                EditorInspectorField(id: "particle-policy-target-live", label: L("Target Live"),
                                     value: .constrainedNumber(particleScalabilityPolicyIntBinding(\.targetLiveParticles),
                                                               min: 0, max: 1_000_000, step: 100, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-target-spawn", label: L("Target Spawn"),
                                     value: .constrainedNumber(particleScalabilityPolicyIntBinding(\.targetSpawnedParticlesPerFrame),
                                                               min: 0, max: 1_000_000, step: 10, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-min-scale", label: L("Minimum Scale"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.minimumScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-pressure-step", label: L("Pressure Step"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.pressureStep),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-recovery-step", label: L("Recovery Step"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.recoveryStep),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-applied-scale", label: L("Applied Scale"),
                                     value: .readOnly(format(state.appliedScale))),
                EditorInspectorField(id: "particle-policy-pressure", label: L("Pressure"),
                                     value: .readOnly(format(state.pressure))),
                EditorInspectorField(id: "particle-policy-reason", label: L("Reason"),
                                     value: .readOnly(state.reason.rawValue)),
            ]
        )
    }

    private func updateParticleScalability(_ mutate: (inout ParticleScalabilityResource) -> Void) {
        var next = scene.resource(ParticleScalabilityResource.self) ?? .default
        mutate(&next)
        let sanitized = ParticleScalabilityResource(emissionScale: next.emissionScale,
                                                    burstScale: next.burstScale,
                                                    distanceEmissionScale: next.distanceEmissionScale,
                                                    maxLiveParticleScale: next.maxLiveParticleScale)
        guard scene.resource(ParticleScalabilityResource.self) != sanitized else { return }
        scene.setResource(sanitized)
        notifyRevisionChanged()
    }

    private func updateParticleScalabilityPolicy(_ mutate: (inout ParticleScalabilityPolicyResource) -> Void) {
        var next = scene.resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        mutate(&next)
        let sanitized = ParticleScalabilityPolicyResource(isEnabled: next.isEnabled,
                                                          targetLiveParticles: next.targetLiveParticles,
                                                          targetSpawnedParticlesPerFrame: next.targetSpawnedParticlesPerFrame,
                                                          minimumScale: next.minimumScale,
                                                          pressureStep: next.pressureStep,
                                                          recoveryStep: next.recoveryStep)
        guard scene.resource(ParticleScalabilityPolicyResource.self) != sanitized else { return }
        scene.setResource(sanitized)
        notifyRevisionChanged()
    }

    private func particleScalabilityFloatBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityResource, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityResource.self)?[keyPath: keyPath] ?? 1 },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityResource.self)?[keyPath: keyPath] != next else { return }
                updateParticleScalability { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleScalabilityPolicyEnabledBinding() -> Binding<Bool> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled ?? false },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled != next else { return }
                updateParticleScalabilityPolicy { $0.isEnabled = next }
            }
        )
    }

    private func particleScalabilityPolicyFloatBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityPolicyResource, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath]
                ?? ParticleScalabilityPolicyResource.disabled[keyPath: keyPath] },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath] != next else { return }
                updateParticleScalabilityPolicy { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleScalabilityPolicyIntBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityPolicyResource, Int>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath]
                      ?? ParticleScalabilityPolicyResource.disabled[keyPath: keyPath])
            },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath] != value else { return }
                updateParticleScalabilityPolicy { $0[keyPath: keyPath] = value }
            }
        )
    }
}
