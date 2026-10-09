import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func rigidBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let body = scene.component(RigidBody.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "rigid-body",
            title: L("Rigid Body"),
            fields: [
                EditorInspectorField(
                    id: "motion",
                    label: L("Motion"),
                    value: .rigidBodyMotion(rigidBodyMotionBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mass",
                    label: L("Mass"),
                    value: .constrainedNumber(rigidBodyMassBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.5,
                                              showsStepper: true)
                ),
                EditorInspectorField(id: "mass-mode", label: L("Mass Mode"), value: .readOnly(body.massMode.rawValue)),
                EditorInspectorField(id: "max-linear-velocity", label: L("Max Linear Velocity"), value: .readOnly(format(body.maxLinearVelocity))),
                EditorInspectorField(id: "max-angular-velocity", label: L("Max Angular Velocity"), value: .readOnly(format(body.maxAngularVelocity))),
                EditorInspectorField(id: "axis-locks", label: L("Axis Locks"), value: .readOnly(String(body.axisLocks.rawValue))),
                EditorInspectorField(
                    id: "linear-velocity",
                    label: L("Linear Velocity"),
                    value: .vector3(x: rigidBodyLinearVelocityBinding(for: entity, axis: \.x),
                                    y: rigidBodyLinearVelocityBinding(for: entity, axis: \.y),
                                    z: rigidBodyLinearVelocityBinding(for: entity, axis: \.z))
                ),
                EditorInspectorField(
                    id: "angular-velocity",
                    label: L("Angular Velocity"),
                    value: .vector3(x: rigidBodyAngularVelocityBinding(for: entity, axis: \.x),
                                    y: rigidBodyAngularVelocityBinding(for: entity, axis: \.y),
                                    z: rigidBodyAngularVelocityBinding(for: entity, axis: \.z))
                ),
                EditorInspectorField(
                    id: "gravity-scale",
                    label: L("Gravity"),
                    value: .constrainedNumber(rigidBodyGravityScaleBinding(for: entity),
                                              min: nil,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "linear-damping",
                    label: L("Linear Damping"),
                    value: .constrainedNumber(rigidBodyLinearDampingBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.01,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "angular-damping",
                    label: L("Angular Damping"),
                    value: .constrainedNumber(rigidBodyAngularDampingBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.01,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "continuous-collision-detection",
                    label: L("Continuous Collision"),
                    value: .bool(rigidBodyContinuousCollisionBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "allow-sleep",
                    label: L("Allow Sleep"),
                    value: .bool(rigidBodyAllowSleepBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "sleeping",
                    label: L("Sleeping"),
                    value: .readOnly(body.isSleeping ? L("Yes") : L("No"))
                ),
            ]
        )
    }

    private func rigidBodyAllowSleepBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.allowSleep ?? false
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.allowSleep != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_allow_sleep",
                                          summary: "Update rigid body sleep flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "rigidbody", fields: ["allowSleep": (next)])])
            }
        )
    }

    private func rigidBodyMotionBinding(for entity: EntityID) -> Binding<RigidBodyMotionType> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.motionType ?? .dynamic
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.motionType != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_motion",
                                          summary: "Update rigid body motion type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "rigidbody", fields: ["motionType": (next).rawValue])])
            }
        )
    }

    private func rigidBodyMassBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.mass ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(RigidBody.self, for: entity)?.mass != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_mass",
                                          summary: "Update rigid body mass",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "rigidbody", fields: ["mass": (clamped)])])
            }
        )
    }

    private func rigidBodyGravityScaleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.gravityScale ?? 0
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.gravityScale != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_gravity_scale",
                                          summary: "Update rigid body gravity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "rigidbody", fields: ["gravityScale": (next)])])
            }
        )
    }

    private func rigidBodyLinearVelocityBinding(
        for entity: EntityID,
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.linearVelocity[keyPath: axis] ?? 0
            },
            set: { [self] next in
                guard var body = scene.component(RigidBody.self, for: entity),
                      body.linearVelocity[keyPath: axis] != next else { return }
                body.linearVelocity[keyPath: axis] = next
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_linear_velocity",
                                          summary: "Update rigid body linear velocity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentData(entityID: entity.rawValue, typeID: "rigidbody", component: body)])
            }
        )
    }

    private func rigidBodyAngularVelocityBinding(
        for entity: EntityID,
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.angularVelocity[keyPath: axis] ?? 0
            },
            set: { [self] next in
                guard var body = scene.component(RigidBody.self, for: entity),
                      body.angularVelocity[keyPath: axis] != next else { return }
                body.angularVelocity[keyPath: axis] = next
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_angular_velocity",
                                          summary: "Update rigid body angular velocity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentData(entityID: entity.rawValue, typeID: "rigidbody", component: body)])
            }
        )
    }

    private func rigidBodyLinearDampingBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.linearDamping ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard var body = scene.component(RigidBody.self, for: entity),
                      body.linearDamping != clamped else { return }
                body.linearDamping = clamped
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_linear_damping",
                                          summary: "Update rigid body linear damping",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentData(entityID: entity.rawValue, typeID: "rigidbody", component: body)])
            }
        )
    }

    private func rigidBodyAngularDampingBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.angularDamping ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard var body = scene.component(RigidBody.self, for: entity),
                      body.angularDamping != clamped else { return }
                body.angularDamping = clamped
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_angular_damping",
                                          summary: "Update rigid body angular damping",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentData(entityID: entity.rawValue, typeID: "rigidbody", component: body)])
            }
        )
    }

    private func rigidBodyContinuousCollisionBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.continuousCollisionDetection ?? false
            },
            set: { [self] next in
                guard var body = scene.component(RigidBody.self, for: entity),
                      body.continuousCollisionDetection != next else { return }
                body.continuousCollisionDetection = next
                body.motionQuality = next ? .linearCast : .discrete
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_ccd",
                                          summary: "Update rigid body continuous collision detection",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentData(entityID: entity.rawValue, typeID: "rigidbody", component: body)])
            }
        )
    }
}
