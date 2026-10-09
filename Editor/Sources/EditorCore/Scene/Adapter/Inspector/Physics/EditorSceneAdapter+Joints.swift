import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func constraintSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let joint = scene.component(PhysicsJoint.self, for: entity) else {
            return nil
        }
        let endpointOptions = physicsJointEndpointOptions(excluding: entity)

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "joint-type",
                label: L("Type"),
                value: .physicsJointKind(physicsJointKindBinding(for: entity))
            ),
            EditorInspectorField(
                id: "joint-entity-a",
                label: L("Entity A"),
                value: .entityReference(
                    physicsJointEndpointBinding(for: entity, endpoint: .a),
                    options: endpointOptions
                )
            ),
            EditorInspectorField(
                id: "joint-entity-b",
                label: L("Entity B"),
                value: .entityReference(
                    physicsJointEndpointBinding(for: entity, endpoint: .b),
                    options: endpointOptions
                )
            ),
            jointVectorField("joint-pivot-a", L("Anchor A"), entity, .pivotA),
            jointVectorField("joint-pivot-b", L("Anchor B"), entity, .pivotB),
        ]

        switch joint.configuration {
        case .point:
            break
        case .fixed:
            fields.append(jointVectorField("joint-axis-a", L("Axis A"), entity, .axisA))
            fields.append(jointVectorField("joint-axis-b", L("Axis B"), entity, .axisB))
        case .distance:
            fields.append(jointScalarField("joint-minimum-distance", L("Minimum Distance"), entity, .minimumLimit, min: 0))
            fields.append(jointScalarField("joint-maximum-distance", L("Maximum Distance"), entity, .maximumLimit, min: 0))
            fields.append(contentsOf: jointSpringFields(for: entity))
        case .hinge:
            fields.append(jointVectorField("joint-axis-a", L("Axis A"), entity, .axisA))
            fields.append(jointVectorField("joint-axis-b", L("Axis B"), entity, .axisB))
            fields.append(jointScalarField("joint-minimum-angle", L("Minimum Angle (rad)"), entity, .minimumLimit))
            fields.append(jointScalarField("joint-maximum-angle", L("Maximum Angle (rad)"), entity, .maximumLimit))
            fields.append(contentsOf: jointMotorFields(for: entity, slot: .primary))
            fields.append(contentsOf: jointSpringFields(for: entity))
        case .slider:
            fields.append(jointVectorField("joint-axis-a", L("Axis A"), entity, .axisA))
            fields.append(jointVectorField("joint-axis-b", L("Axis B"), entity, .axisB))
            fields.append(jointScalarField("joint-minimum-distance", L("Minimum Distance"), entity, .minimumLimit))
            fields.append(jointScalarField("joint-maximum-distance", L("Maximum Distance"), entity, .maximumLimit))
            fields.append(contentsOf: jointMotorFields(for: entity, slot: .primary))
            fields.append(contentsOf: jointSpringFields(for: entity))
        case .cone:
            fields.append(jointVectorField("joint-axis-a", L("Twist Axis A"), entity, .axisA))
            fields.append(jointVectorField("joint-axis-b", L("Twist Axis B"), entity, .axisB))
            fields.append(jointScalarField("joint-half-cone-angle", L("Half Cone Angle (rad)"), entity, .halfConeAngle, min: 0))
            fields.append(jointScalarField("joint-minimum-angle", L("Minimum Twist (rad)"), entity, .minimumLimit))
            fields.append(jointScalarField("joint-maximum-angle", L("Maximum Twist (rad)"), entity, .maximumLimit))
            fields.append(contentsOf: jointSpringFields(for: entity))
        case .sixDOF:
            fields.append(jointVectorField("joint-axis-a", L("Axis A"), entity, .axisA))
            fields.append(jointVectorField("joint-axis-b", L("Axis B"), entity, .axisB))
            fields.append(jointVectorField("joint-linear-minimum", L("Linear Minimum"), entity, .linearMinimum))
            fields.append(jointVectorField("joint-linear-maximum", L("Linear Maximum"), entity, .linearMaximum))
            fields.append(jointVectorField("joint-angular-minimum", L("Angular Minimum"), entity, .angularMinimum))
            fields.append(jointVectorField("joint-angular-maximum", L("Angular Maximum"), entity, .angularMaximum))
            fields.append(contentsOf: jointMotorFields(for: entity, slot: .primary, prefix: "linear", label: L("Linear")))
            fields.append(contentsOf: jointMotorFields(for: entity, slot: .angular, prefix: "angular", label: L("Angular")))
            fields.append(contentsOf: jointSpringFields(for: entity))
        }

        fields.append(contentsOf: [
            jointScalarField("joint-break-force", L("Break Force"), entity, .breakForce, min: 0),
            jointScalarField("joint-break-torque", L("Break Torque"), entity, .breakTorque, min: 0),
            EditorInspectorField(
                id: "joint-enabled",
                label: L("Enabled"),
                value: .bool(constraintEnabledBinding(for: entity))
            ),
        ])

        return EditorInspectorSection(
            id: "constraint",
            title: L("Physics Joint"),
            fields: fields
        )
    }

    private enum PhysicsJointVectorField: Equatable {
        case pivotA, pivotB, axisA, axisB
        case linearMinimum, linearMaximum, angularMinimum, angularMaximum
    }

    private enum PhysicsJointScalarField: Equatable {
        case minimumLimit, maximumLimit, halfConeAngle
        case springFrequency, springDamping
        case breakForce, breakTorque
    }

    private enum PhysicsJointMotorSlot: Equatable { case primary, angular }
    private enum PhysicsJointMotorScalarField { case targetPosition, targetVelocity, maximumForce }
    private enum PhysicsJointEndpoint: Equatable { case a, b }

    private func physicsJointEndpointOptions(
        excluding jointEntity: EntityID
    ) -> [EditorInspectorEntityOption] {
        scene.entities()
            .filter { entity in
                entity != jointEntity && scene.component(Collider.self, for: entity) != nil
            }
            .sorted { $0.rawValue < $1.rawValue }
            .map {
                EditorInspectorEntityOption(id: $0.rawValue, name: displayName(for: $0))
            }
    }

    private func physicsJointEndpointBinding(
        for jointEntity: EntityID,
        endpoint: PhysicsJointEndpoint
    ) -> Binding<UInt64> {
        Binding(
            get: { [self] in
                guard let joint = scene.component(PhysicsJoint.self, for: jointEntity) else { return 0 }
                return endpoint == .a ? joint.entityA.rawValue : joint.entityB.rawValue
            },
            set: { [self] rawID in
                let candidate = EntityID(rawValue: rawID)
                guard let current = scene.component(PhysicsJoint.self, for: jointEntity) else { return }
                let existing = endpoint == .a ? current.entityA : current.entityB
                let other = endpoint == .a ? current.entityB : current.entityA
                guard scene.contains(candidate),
                      scene.component(Collider.self, for: candidate) != nil,
                      candidate != existing,
                      candidate != other,
                      updateComponentData(PhysicsJoint.self, for: jointEntity, { joint in
                          if endpoint == .a { joint.entityA = candidate }
                          else { joint.entityB = candidate }
                      })
                else { return }
            }
        )
    }

    private func jointVectorField(
        _ id: String,
        _ label: String,
        _ entity: EntityID,
        _ field: PhysicsJointVectorField
    ) -> EditorInspectorField {
        EditorInspectorField(
            id: id,
            label: label,
            value: .vector3(
                x: physicsJointVectorBinding(for: entity, field: field, axis: \.x),
                y: physicsJointVectorBinding(for: entity, field: field, axis: \.y),
                z: physicsJointVectorBinding(for: entity, field: field, axis: \.z)
            )
        )
    }

    private func jointScalarField(
        _ id: String,
        _ label: String,
        _ entity: EntityID,
        _ field: PhysicsJointScalarField,
        min minimum: Float? = nil
    ) -> EditorInspectorField {
        EditorInspectorField(
            id: id,
            label: label,
            value: .constrainedNumber(
                physicsJointScalarBinding(for: entity, field: field, minimum: minimum),
                min: minimum,
                max: nil,
                step: 0.05,
                showsStepper: true
            )
        )
    }

    private func jointSpringFields(for entity: EntityID) -> [EditorInspectorField] {
        [
            jointScalarField("joint-spring-frequency", L("Spring Frequency"), entity, .springFrequency, min: 0),
            jointScalarField("joint-spring-damping", L("Spring Damping"), entity, .springDamping, min: 0),
        ]
    }

    private func jointMotorFields(
        for entity: EntityID,
        slot: PhysicsJointMotorSlot,
        prefix: String = "motor",
        label: String = "Motor"
    ) -> [EditorInspectorField] {
        [
            EditorInspectorField(
                id: "joint-\(prefix)-mode",
                label: "\(label) \(L("Mode"))",
                value: .physicsJointMotorMode(physicsJointMotorModeBinding(for: entity, slot: slot))
            ),
            EditorInspectorField(
                id: "joint-\(prefix)-target-position",
                label: "\(label) \(L("Target Position"))",
                value: .number(physicsJointMotorScalarBinding(for: entity, slot: slot, field: .targetPosition))
            ),
            EditorInspectorField(
                id: "joint-\(prefix)-target-velocity",
                label: "\(label) \(L("Target Velocity"))",
                value: .number(physicsJointMotorScalarBinding(for: entity, slot: slot, field: .targetVelocity))
            ),
            EditorInspectorField(
                id: "joint-\(prefix)-maximum-force",
                label: "\(label) \(L("Maximum Force"))",
                value: .constrainedNumber(
                    physicsJointMotorScalarBinding(for: entity, slot: slot, field: .maximumForce),
                    min: 0,
                    max: nil,
                    step: 1,
                    showsStepper: true
                )
            ),
        ]
    }

    private func physicsJointKindBinding(for entity: EntityID) -> Binding<PhysicsJointKind> {
        Binding(
            get: { [self] in
                scene.component(PhysicsJoint.self, for: entity)?.configuration.kind ?? .pointToPoint
            },
            set: { [self] kind in
                guard updateComponentData(PhysicsJoint.self, for: entity, { joint in
                    guard joint.configuration.kind != kind else { return }
                    joint.configuration = switch kind {
                    case .pointToPoint: .point
                    case .fixed: .fixed(axisA: SIMD3<Float>(0, 1, 0), axisB: SIMD3<Float>(0, 1, 0))
                    case .distance: .distance(DistanceJointConfiguration(maximumDistance: 1))
                    case .hinge: .hinge(HingeJointConfiguration())
                    case .slider: .slider(SliderJointConfiguration())
                    case .cone: .cone(ConeJointConfiguration())
                    case .sixDOF: .sixDOF(SixDOFJointConfiguration())
                    }
                }) else { return }
            }
        )
    }

    private func physicsJointVectorBinding(
        for entity: EntityID,
        field: PhysicsJointVectorField,
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let joint = scene.component(PhysicsJoint.self, for: entity) else { return 0 }
                return physicsJointVector(joint, field: field)[keyPath: axis]
            },
            set: { [self] next in
                guard updateComponentData(PhysicsJoint.self, for: entity, { joint in
                    var vector = physicsJointVector(joint, field: field)
                    guard vector[keyPath: axis] != next else { return }
                    vector[keyPath: axis] = next
                    setPhysicsJointVector(vector, field: field, joint: &joint)
                }) else { return }
            }
        )
    }

    private func physicsJointVector(
        _ joint: PhysicsJoint,
        field: PhysicsJointVectorField
    ) -> SIMD3<Float> {
        switch field {
        case .pivotA: return joint.pivotA
        case .pivotB: return joint.pivotB
        case .axisA: return joint.axisA
        case .axisB: return joint.axisB
        case .linearMinimum:
            if case let .sixDOF(value) = joint.configuration { return value.linearMinimum }
        case .linearMaximum:
            if case let .sixDOF(value) = joint.configuration { return value.linearMaximum }
        case .angularMinimum:
            if case let .sixDOF(value) = joint.configuration { return value.angularMinimum }
        case .angularMaximum:
            if case let .sixDOF(value) = joint.configuration { return value.angularMaximum }
        }
        return .zero
    }

    private func setPhysicsJointVector(
        _ vector: SIMD3<Float>,
        field: PhysicsJointVectorField,
        joint: inout PhysicsJoint
    ) {
        switch field {
        case .pivotA: joint.pivotA = vector
        case .pivotB: joint.pivotB = vector
        case .axisA: joint.axisA = vector
        case .axisB: joint.axisB = vector
        case .linearMinimum:
            guard case var .sixDOF(value) = joint.configuration else { return }
            value.linearMinimum = simd_min(vector, value.linearMaximum)
            joint.configuration = .sixDOF(value)
        case .linearMaximum:
            guard case var .sixDOF(value) = joint.configuration else { return }
            value.linearMaximum = simd_max(vector, value.linearMinimum)
            joint.configuration = .sixDOF(value)
        case .angularMinimum:
            guard case var .sixDOF(value) = joint.configuration else { return }
            value.angularMinimum = simd_min(vector, value.angularMaximum)
            joint.configuration = .sixDOF(value)
        case .angularMaximum:
            guard case var .sixDOF(value) = joint.configuration else { return }
            value.angularMaximum = simd_max(vector, value.angularMinimum)
            joint.configuration = .sixDOF(value)
        }
    }

    private func physicsJointScalarBinding(
        for entity: EntityID,
        field: PhysicsJointScalarField,
        minimum: Float?
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let joint = scene.component(PhysicsJoint.self, for: entity) else { return 0 }
                return physicsJointScalar(joint, field: field)
            },
            set: { [self] next in
                let value = minimum.map { max($0, next) } ?? next
                guard updateComponentData(PhysicsJoint.self, for: entity, { joint in
                    guard physicsJointScalar(joint, field: field) != value else { return }
                    setPhysicsJointScalar(value, field: field, joint: &joint)
                }) else { return }
            }
        )
    }

    private func physicsJointScalar(
        _ joint: PhysicsJoint,
        field: PhysicsJointScalarField
    ) -> Float {
        switch field {
        case .minimumLimit: return joint.minLimit
        case .maximumLimit: return joint.maxLimit
        case .halfConeAngle:
            if case let .cone(value) = joint.configuration { return value.halfConeAngle }
            return 0
        case .springFrequency: return physicsJointSpring(joint)?.frequency ?? 0
        case .springDamping: return physicsJointSpring(joint)?.damping ?? 0
        case .breakForce: return joint.breakForce
        case .breakTorque: return joint.breakTorque
        }
    }

    private func setPhysicsJointScalar(
        _ scalar: Float,
        field: PhysicsJointScalarField,
        joint: inout PhysicsJoint
    ) {
        switch field {
        case .minimumLimit:
            switch joint.configuration {
            case var .distance(value): value.minimumDistance = min(max(0, scalar), value.maximumDistance); joint.configuration = .distance(value)
            case var .hinge(value): value.minimumAngle = min(scalar, value.maximumAngle); joint.configuration = .hinge(value)
            case var .slider(value): value.minimumDistance = min(scalar, value.maximumDistance); joint.configuration = .slider(value)
            case var .cone(value): value.minimumTwistAngle = min(scalar, value.maximumTwistAngle); joint.configuration = .cone(value)
            default: break
            }
        case .maximumLimit:
            switch joint.configuration {
            case var .distance(value): value.maximumDistance = max(max(0, scalar), value.minimumDistance); joint.configuration = .distance(value)
            case var .hinge(value): value.maximumAngle = max(scalar, value.minimumAngle); joint.configuration = .hinge(value)
            case var .slider(value): value.maximumDistance = max(scalar, value.minimumDistance); joint.configuration = .slider(value)
            case var .cone(value): value.maximumTwistAngle = max(scalar, value.minimumTwistAngle); joint.configuration = .cone(value)
            default: break
            }
        case .halfConeAngle:
            guard case var .cone(value) = joint.configuration else { return }
            value.halfConeAngle = max(0, scalar)
            joint.configuration = .cone(value)
        case .springFrequency, .springDamping:
            guard var spring = physicsJointSpring(joint) else { return }
            if field == .springFrequency { spring.frequency = max(0, scalar) }
            else { spring.damping = max(0, scalar) }
            setPhysicsJointSpring(spring, joint: &joint)
        case .breakForce: joint.breakForce = max(0, scalar)
        case .breakTorque: joint.breakTorque = max(0, scalar)
        }
    }

    private func physicsJointSpring(_ joint: PhysicsJoint) -> PhysicsJointSpring? {
        switch joint.configuration {
        case let .distance(value): return value.spring
        case let .hinge(value): return value.spring
        case let .slider(value): return value.spring
        case let .cone(value): return value.spring
        case let .sixDOF(value): return value.spring
        default: return nil
        }
    }

    private func setPhysicsJointSpring(_ spring: PhysicsJointSpring, joint: inout PhysicsJoint) {
        switch joint.configuration {
        case var .distance(value): value.spring = spring; joint.configuration = .distance(value)
        case var .hinge(value): value.spring = spring; joint.configuration = .hinge(value)
        case var .slider(value): value.spring = spring; joint.configuration = .slider(value)
        case var .cone(value): value.spring = spring; joint.configuration = .cone(value)
        case var .sixDOF(value): value.spring = spring; joint.configuration = .sixDOF(value)
        default: break
        }
    }

    private func physicsJointMotorModeBinding(
        for entity: EntityID,
        slot: PhysicsJointMotorSlot
    ) -> Binding<PhysicsJointMotorMode> {
        Binding(
            get: { [self] in physicsJointMotor(for: entity, slot: slot)?.mode ?? .disabled },
            set: { [self] mode in
                updatePhysicsJointMotor(for: entity, slot: slot) { $0.mode = mode }
            }
        )
    }

    private func physicsJointMotorScalarBinding(
        for entity: EntityID,
        slot: PhysicsJointMotorSlot,
        field: PhysicsJointMotorScalarField
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let motor = physicsJointMotor(for: entity, slot: slot) else { return 0 }
                return switch field {
                case .targetPosition: motor.targetPosition
                case .targetVelocity: motor.targetVelocity
                case .maximumForce: motor.maxForce
                }
            },
            set: { [self] value in
                updatePhysicsJointMotor(for: entity, slot: slot) { motor in
                    switch field {
                    case .targetPosition: motor.targetPosition = value
                    case .targetVelocity: motor.targetVelocity = value
                    case .maximumForce: motor.maxForce = max(0, value)
                    }
                }
            }
        )
    }

    private func physicsJointMotor(
        for entity: EntityID,
        slot: PhysicsJointMotorSlot
    ) -> PhysicsJointMotor? {
        guard let joint = scene.component(PhysicsJoint.self, for: entity) else { return nil }
        switch joint.configuration {
        case let .hinge(value): return slot == .primary ? value.motor : nil
        case let .slider(value): return slot == .primary ? value.motor : nil
        case let .sixDOF(value): return slot == .primary ? value.linearMotor : value.angularMotor
        default: return nil
        }
    }

    private func updatePhysicsJointMotor(
        for entity: EntityID,
        slot: PhysicsJointMotorSlot,
        update: (inout PhysicsJointMotor) -> Void
    ) {
        guard updateComponentData(PhysicsJoint.self, for: entity, { joint in
            switch joint.configuration {
            case var .hinge(value):
                guard slot == .primary else { return }
                update(&value.motor); joint.configuration = .hinge(value)
            case var .slider(value):
                guard slot == .primary else { return }
                update(&value.motor); joint.configuration = .slider(value)
            case var .sixDOF(value):
                if slot == .primary { update(&value.linearMotor) }
                else { update(&value.angularMotor) }
                joint.configuration = .sixDOF(value)
            default: break
            }
        }) else { return }
    }

    private func constraintEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Constraint.self, for: entity)?.isEnabled ?? false
            },
            set: { [self] next in
                guard scene.component(Constraint.self, for: entity)?.isEnabled != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_constraint_enabled",
                                          summary: "Update constraint enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "constraint", fields: ["isEnabled": (next)])])
            }
        )
    }
}
