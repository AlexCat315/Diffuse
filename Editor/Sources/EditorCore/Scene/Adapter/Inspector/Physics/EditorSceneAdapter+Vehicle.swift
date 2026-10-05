import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func vehicleSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let vehicle = scene.component(Vehicle.self, for: entity) else { return nil }
        let state = scene.vehicleStateFrame.states[entity]
        let contactCount = state?.wheels.filter(\.hasContact).count ?? 0
        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "vehicle-enabled", label: L("Enabled"),
                value: .bool(vehicleEnabledBinding(for: entity))
            ),
            EditorInspectorField(
                id: "vehicle-controller", label: L("Controller"),
                value: .vehicleControllerKind(vehicleControllerKindBinding(for: entity))
            ),
            EditorInspectorField(
                id: "vehicle-wheels", label: L("Wheels"),
                value: .readOnly(String(vehicle.wheels.count))
            ),
            EditorInspectorField(
                id: "vehicle-differentials", label: L("Differentials"),
                value: .readOnly(String(vehicle.differentials.count))
            ),
            EditorInspectorField(
                id: "vehicle-transmission", label: L("Transmission"),
                value: .readOnly(vehicle.transmission.mode == .automatic ? L("Automatic") : L("Manual"))
            ),
            EditorInspectorField(
                id: "vehicle-max-torque", label: L("Max Torque"),
                value: .constrainedNumber(
                    vehicleEngineFloatBinding(for: entity, \.maxTorque, min: 0),
                    min: 0, max: nil, step: 10, showsStepper: true
                )
            ),
            EditorInspectorField(
                id: "vehicle-clutch-strength", label: L("Clutch Strength"),
                value: .constrainedNumber(
                    vehicleTransmissionFloatBinding(for: entity, \.clutchStrength, min: 0),
                    min: 0, max: nil, step: 0.5, showsStepper: true
                )
            ),
        ]
        switch vehicle.controller {
        case .wheeled:
            break
        case .tracked:
            fields.append(EditorInspectorField(
                id: "vehicle-track-longitudinal-friction",
                label: L("Track Forward Friction"),
                value: .constrainedNumber(
                    vehicleTrackedFloatBinding(for: entity, \.longitudinalFriction, min: 0),
                    min: 0, max: nil, step: 0.1, showsStepper: true
                )
            ))
            fields.append(EditorInspectorField(
                id: "vehicle-track-lateral-friction",
                label: L("Track Side Friction"),
                value: .constrainedNumber(
                    vehicleTrackedFloatBinding(for: entity, \.lateralFriction, min: 0),
                    min: 0, max: nil, step: 0.1, showsStepper: true
                )
            ))
        case .motorcycle:
            fields.append(EditorInspectorField(
                id: "vehicle-motorcycle-max-lean",
                label: L("Max Lean Angle"),
                value: .constrainedNumber(
                    vehicleMotorcycleFloatBinding(for: entity, \.maxLeanAngle, min: 0, max: .pi / 2),
                    min: 0, max: .pi / 2, step: 0.05, showsStepper: true
                )
            ))
            fields.append(EditorInspectorField(
                id: "vehicle-motorcycle-lean-spring",
                label: L("Lean Spring"),
                value: .constrainedNumber(
                    vehicleMotorcycleFloatBinding(for: entity, \.leanSpringConstant, min: 0),
                    min: 0, max: nil, step: 100, showsStepper: true
                )
            ))
            fields.append(EditorInspectorField(
                id: "vehicle-motorcycle-lean-enabled",
                label: L("Lean Controller"),
                value: .bool(vehicleMotorcycleLeanEnabledBinding(for: entity))
            ))
        }
        fields.append(contentsOf: [
            EditorInspectorField(
                id: "vehicle-speed", label: L("Forward Speed"),
                value: .readOnly(format(state?.forwardSpeed ?? 0))
            ),
            EditorInspectorField(
                id: "vehicle-engine-rpm", label: L("Engine RPM"),
                value: .readOnly(format(state?.engineRPM ?? 0))
            ),
            EditorInspectorField(
                id: "vehicle-current-gear", label: L("Current Gear"),
                value: .readOnly(String(state?.currentGear ?? 0))
            ),
            EditorInspectorField(
                id: "vehicle-wheel-contacts", label: L("Wheel Contacts"),
                value: .readOnly("\(contactCount) / \(vehicle.wheels.count)")
            ),
        ])
        return EditorInspectorSection(id: "vehicle", title: L("Vehicle"), fields: fields)
    }

    func ragdollSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let ragdoll = scene.component(Ragdoll.self, for: entity) else { return nil }
        let state = scene.ragdollStateFrame.states[entity]
        return EditorInspectorSection(
            id: "ragdoll",
            title: L("Ragdoll"),
            fields: [
                EditorInspectorField(id: "ragdoll-enabled", label: L("Enabled"), value: .bool(ragdollEnabledBinding(for: entity))),
                EditorInspectorField(id: "ragdoll-mode", label: L("Mode"), value: .readOnly(ragdoll.mode.rawValue)),
                EditorInspectorField(
                    id: "ragdoll-blend-weight",
                    label: L("Blend Weight"),
                    value: .constrainedNumber(
                        ragdollBlendWeightBinding(for: entity),
                        min: 0,
                        max: 1,
                        step: 0.05,
                        showsStepper: true
                    )
                ),
                EditorInspectorField(id: "ragdoll-bones", label: L("Bones"), value: .readOnly(String(ragdoll.bones.count))),
                EditorInspectorField(
                    id: "ragdoll-simulated-bones",
                    label: L("Simulated Bones"),
                    value: .readOnly(String(state?.bones.filter(\.isSimulated).count ?? 0))
                ),
            ]
        )
    }

    private func vehicleControllerKindBinding(for entity: EntityID) -> Binding<VehicleControllerKind> {
        Binding(
            get: { [self] in
                scene.component(Vehicle.self, for: entity)?.controller.kind ?? .wheeled
            },
            set: { [self] kind in
                guard let current = scene.component(Vehicle.self, for: entity),
                      current.controller.kind != kind else { return }
                var next: Vehicle
                switch kind {
                case .wheeled:
                    next = Vehicle(engine: current.engine, transmission: current.transmission)
                case .tracked:
                    next = Vehicle.tracked(
                        engine: current.engine,
                        transmission: current.transmission
                    )
                case .motorcycle:
                    next = Vehicle.motorcycle(
                        engine: current.engine,
                        transmission: current.transmission
                    )
                }
                next.up = current.up
                next.forward = current.forward
                next.maxPitchRollAngle = current.maxPitchRollAngle
                next.isEnabled = current.isEnabled
                guard scene.setComponent(next, for: entity) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in scene.component(Vehicle.self, for: entity)?.isEnabled ?? false },
            set: { [self] value in
                guard scene.component(Vehicle.self, for: entity)?.isEnabled != value else { return }
                _ = scene.updateComponent(Vehicle.self, for: entity) { $0.isEnabled = value }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleEngineFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<VehicleEngineConfiguration, Float>,
        min minimum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Vehicle.self, for: entity)?.engine[keyPath: keyPath] ?? 0
            },
            set: { [self] next in
                let value = minimum.map { Swift.max($0, next) } ?? next
                guard scene.updateComponent(Vehicle.self, for: entity, {
                    $0.engine[keyPath: keyPath] = value
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleTransmissionFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<VehicleTransmissionConfiguration, Float>,
        min minimum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Vehicle.self, for: entity)?.transmission[keyPath: keyPath] ?? 0
            },
            set: { [self] next in
                let value = minimum.map { Swift.max($0, next) } ?? next
                guard scene.updateComponent(Vehicle.self, for: entity, {
                    $0.transmission[keyPath: keyPath] = value
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleTrackedFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<TrackedVehicleConfiguration, Float>,
        min minimum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard case let .tracked(configuration)? =
                    scene.component(Vehicle.self, for: entity)?.controller
                else { return 0 }
                return configuration[keyPath: keyPath]
            },
            set: { [self] next in
                let value = minimum.map { Swift.max($0, next) } ?? next
                guard scene.updateComponent(Vehicle.self, for: entity, { vehicle in
                    guard case var .tracked(configuration) = vehicle.controller else { return }
                    configuration[keyPath: keyPath] = value
                    vehicle.controller = .tracked(configuration)
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleMotorcycleFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<MotorcycleVehicleConfiguration, Float>,
        min minimum: Float? = nil,
        max maximum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard case let .motorcycle(configuration)? =
                    scene.component(Vehicle.self, for: entity)?.controller
                else { return 0 }
                return configuration[keyPath: keyPath]
            },
            set: { [self] next in
                var value = minimum.map { Swift.max($0, next) } ?? next
                value = maximum.map { Swift.min($0, value) } ?? value
                guard scene.updateComponent(Vehicle.self, for: entity, { vehicle in
                    guard case var .motorcycle(configuration) = vehicle.controller else { return }
                    configuration[keyPath: keyPath] = value
                    vehicle.controller = .motorcycle(configuration)
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func vehicleMotorcycleLeanEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                guard case let .motorcycle(configuration)? =
                    scene.component(Vehicle.self, for: entity)?.controller
                else { return false }
                return configuration.isLeanControllerEnabled
            },
            set: { [self] value in
                guard scene.updateComponent(Vehicle.self, for: entity, { vehicle in
                    guard case var .motorcycle(configuration) = vehicle.controller else { return }
                    configuration.isLeanControllerEnabled = value
                    vehicle.controller = .motorcycle(configuration)
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func ragdollEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in scene.component(Ragdoll.self, for: entity)?.isEnabled ?? false },
            set: { [self] value in
                guard scene.component(Ragdoll.self, for: entity)?.isEnabled != value else { return }
                _ = scene.updateComponent(Ragdoll.self, for: entity) { $0.isEnabled = value }
                notifyRevisionChanged()
            }
        )
    }

    private func ragdollBlendWeightBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(Ragdoll.self, for: entity)?.blendWeight ?? 1 },
            set: { [self] value in
                let clamped = max(0, min(value, 1))
                guard scene.component(Ragdoll.self, for: entity)?.blendWeight != clamped else { return }
                _ = scene.updateComponent(Ragdoll.self, for: entity) { $0.blendWeight = clamped }
                notifyRevisionChanged()
            }
        )
    }
}
