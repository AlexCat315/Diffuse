import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func physicsSettingsSection() -> EditorInspectorSection {
        EditorInspectorSection(
            id: "physics-settings",
            title: L("Physics Settings"),
            fields: [
                EditorInspectorField(
                    id: "physics-backend",
                    label: L("Backend"),
                    value: .readOnly("Jolt")
                ),
                EditorInspectorField(
                    id: "physics-simulation-mode",
                    label: L("Simulation Mode"),
                    value: .physicsSimulationMode(physicsSimulationModeBinding())
                ),
                EditorInspectorField(
                    id: "physics-gravity",
                    label: L("Gravity"),
                    value: .vector3(x: physicsGravityBinding(axis: \.x),
                                    y: physicsGravityBinding(axis: \.y),
                                    z: physicsGravityBinding(axis: \.z))
                ),
                EditorInspectorField(
                    id: "physics-fixed-step",
                    label: L("Fixed Time Step"),
                    value: .constrainedNumber(physicsFixedTimeStepBinding(),
                                              min: 0.000_001,
                                              max: 1,
                                              step: 0.001,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-max-substeps",
                    label: L("Max Substeps"),
                    value: .constrainedNumber(physicsIntegerSettingBinding(\.maxSubstepsPerFrame),
                                              min: 1,
                                              max: 64,
                                              step: 1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-collision-steps",
                    label: L("Collision Steps"),
                    value: .constrainedNumber(physicsIntegerSettingBinding(\.collisionSteps),
                                              min: 1,
                                              max: 64,
                                              step: 1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-allow-sleep",
                    label: L("Allow Sleep"),
                    value: .bool(physicsAllowSleepBinding())
                ),
                EditorInspectorField(
                    id: "physics-max-bodies",
                    label: L("Max Bodies"),
                    value: .constrainedNumber(physicsCapacityBinding(\.maxBodies, min: 1, max: 1_000_000),
                                              min: 1, max: 1_000_000, step: 1_024, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-max-body-pairs",
                    label: L("Max Body Pairs"),
                    value: .constrainedNumber(physicsCapacityBinding(\.maxBodyPairs, min: 1, max: 4_000_000),
                                              min: 1, max: 4_000_000, step: 1_024, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-max-contacts",
                    label: L("Max Contacts"),
                    value: .constrainedNumber(physicsCapacityBinding(\.maxContactConstraints, min: 1, max: 1_000_000),
                                              min: 1, max: 1_000_000, step: 1_024, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-temp-memory",
                    label: L("Temp Memory (MiB)"),
                    value: .constrainedNumber(physicsTempAllocatorMiBBinding(),
                                              min: 1, max: 4_095, step: 1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "physics-workers",
                    label: L("Worker Threads (0 = Auto)"),
                    value: .constrainedNumber(physicsCapacityBinding(\.workerThreadCount, min: 0, max: 1_024),
                                              min: 0, max: 1_024, step: 1, showsStepper: true)
                ),
            ]
        )
    }

    private func updatePhysicsSettings(_ mutate: (inout PhysicsSettingsResource) -> Void) {
        var next = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
        mutate(&next)
        let sanitized = PhysicsSettingsResource(
            simulationMode: next.simulationMode,
            backendKind: .jolt,
            gravity: next.gravity,
            fixedTimeStepSeconds: next.fixedTimeStepSeconds,
            maxSubstepsPerFrame: next.maxSubstepsPerFrame,
            allowSleep: next.allowSleep,
            collisionSteps: next.collisionSteps,
            capacity: next.capacity
        )
        guard scene.resource(PhysicsSettingsResource.self) != sanitized else { return }
        scene.setResource(sanitized)
        notifyRevisionChanged()
    }

    private func physicsSimulationModeBinding() -> Binding<PhysicsSimulationMode> {
        Binding(
            get: { [self] in
                scene.resource(PhysicsSettingsResource.self)?.simulationMode ?? .off
            },
            set: { [self] next in
                guard scene.resource(PhysicsSettingsResource.self)?.simulationMode != next else { return }
                updatePhysicsSettings { $0.simulationMode = next }
            }
        )
    }

    private func physicsGravityBinding(
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                (scene.resource(PhysicsSettingsResource.self)?.gravity
                    ?? PhysicsSettingsResource().gravity)[keyPath: axis]
            },
            set: { [self] next in
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard current.gravity[keyPath: axis] != next else { return }
                updatePhysicsSettings { $0.gravity[keyPath: axis] = next }
            }
        )
    }

    private func physicsFixedTimeStepBinding() -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.resource(PhysicsSettingsResource.self)?.fixedTimeStepSeconds
                    ?? PhysicsSettingsResource().fixedTimeStepSeconds)
            },
            set: { [self] next in
                let clamped = max(0.000_001, min(next, 1))
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard Float(current.fixedTimeStepSeconds) != clamped else { return }
                updatePhysicsSettings { $0.fixedTimeStepSeconds = Double(clamped) }
            }
        )
    }

    private func physicsIntegerSettingBinding(
        _ keyPath: WritableKeyPath<PhysicsSettingsResource, Int>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float((scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource())[keyPath: keyPath])
            },
            set: { [self] next in
                let clamped = max(1, min(Int(next.rounded()), 64))
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard current[keyPath: keyPath] != clamped else { return }
                updatePhysicsSettings { $0[keyPath: keyPath] = clamped }
            }
        )
    }

    private func physicsAllowSleepBinding() -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.resource(PhysicsSettingsResource.self)?.allowSleep ?? true
            },
            set: { [self] next in
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard current.allowSleep != next else { return }
                updatePhysicsSettings { $0.allowSleep = next }
            }
        )
    }

    private func physicsCapacityBinding(
        _ keyPath: WritableKeyPath<PhysicsCapacitySettings, Int>,
        min minimum: Int,
        max maximum: Int
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float((scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource())
                    .capacity[keyPath: keyPath])
            },
            set: { [self] next in
                let clamped = max(minimum, min(Int(next.rounded()), maximum))
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard current.capacity[keyPath: keyPath] != clamped else { return }
                updatePhysicsSettings { $0.capacity[keyPath: keyPath] = clamped }
            }
        )
    }

    private func physicsTempAllocatorMiBBinding() -> Binding<Float> {
        Binding(
            get: { [self] in
                let settings = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                return Float(settings.capacity.tempAllocatorBytes) / Float(1_024 * 1_024)
            },
            set: { [self] next in
                let mebibytes = max(1, min(Int(next.rounded()), 4_095))
                let bytes = mebibytes * 1_024 * 1_024
                let current = scene.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
                guard current.capacity.tempAllocatorBytes != bytes else { return }
                updatePhysicsSettings { $0.capacity.tempAllocatorBytes = bytes }
            }
        )
    }
}
