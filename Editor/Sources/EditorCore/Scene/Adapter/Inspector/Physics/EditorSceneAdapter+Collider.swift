import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func colliderSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let collider = scene.component(Collider.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "shape-kind",
                label: L("Shape"),
                value: .colliderShapeKind(colliderShapeKindBinding(for: entity))
            ),
        ]

        switch collider.shape {
        case .box:
            fields.append(
                EditorInspectorField(
                    id: "shape-box-extents",
                    label: L("Half Extents"),
                    value: .vector3(x: colliderBoxHalfExtentsBinding(for: entity, axis: \.x),
                                    y: colliderBoxHalfExtentsBinding(for: entity, axis: \.y),
                                    z: colliderBoxHalfExtentsBinding(for: entity, axis: \.z))
                )
            )
        case .sphere:
            fields.append(
                EditorInspectorField(
                    id: "shape-sphere-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderSphereRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .capsule:
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderCapsuleRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-half-height",
                    label: L("Half Height"),
                    value: .constrainedNumber(colliderCapsuleHalfHeightBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .cylinder:
            fields.append(EditorInspectorField(
                id: "shape-cylinder-radius",
                label: L("Radius"),
                value: .constrainedNumber(colliderCylinderRadiusBinding(for: entity),
                                          min: 0.01, max: nil, step: 0.1, showsStepper: true)
            ))
            fields.append(EditorInspectorField(
                id: "shape-cylinder-half-height",
                label: L("Half Height"),
                value: .constrainedNumber(colliderCylinderHalfHeightBinding(for: entity),
                                          min: 0.01, max: nil, step: 0.1, showsStepper: true)
            ))
        case .heightField:
            fields.append(EditorInspectorField(
                id: "shape-heightfield-resource",
                label: L("Resource"),
                value: .readOnly(collider.shape.resourceID ?? L("(auto)"))
            ))
        case .mesh:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-mesh-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        case .convex:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-convex-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        }

        fields.append(
            EditorInspectorField(
                id: "shape-center",
                label: L("Center"),
                value: .vector3(x: colliderCenterBinding(for: entity, axis: \.x),
                                y: colliderCenterBinding(for: entity, axis: \.y),
                                z: colliderCenterBinding(for: entity, axis: \.z))
            )
        )

        fields.append(EditorInspectorField(
            id: "shape-instance-count",
            label: L("Shape Instances"),
            value: .readOnly(String(collider.shapes.count))
        ))
        fields.append(EditorInspectorField(
            id: "shape-instances",
            label: L("Compound Shapes"),
            value: .colliderShapeInstances(colliderShapeInstanceListBinding(for: entity))
        ))
        fields.append(EditorInspectorField(
            id: "shape-instances-json",
            label: L("Advanced JSON"),
            value: .json(colliderShapeInstancesBinding(for: entity), minHeight: 120),
            presentation: .advanced
        ))

        fields.append(
            EditorInspectorField(
                id: "trigger",
                label: L("Trigger"),
                value: .bool(colliderTriggerBinding(for: entity))
            )
        )

        fields.append(
            EditorInspectorField(
                id: "material-friction",
                label: L("Friction"),
                value: .constrainedNumber(colliderFrictionBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-restitution",
                label: L("Restitution"),
                value: .constrainedNumber(colliderRestitutionBinding(for: entity),
                                          min: 0, max: 1, step: 0.05, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-density",
                label: L("Density"),
                value: .constrainedNumber(colliderDensityBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )

        fields.append(
            EditorInspectorField(
                id: "layer",
                label: L("Layer"),
                value: .constrainedNumber(colliderLayerBinding(for: entity),
                                          min: 0, max: 65535, step: 1, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "layer-mask",
                label: L("Layer Mask"),
                value: .constrainedNumber(colliderLayerMaskBinding(for: entity),
                                          min: 0, max: 65535, step: 1, showsStepper: true)
            )
        )

        return EditorInspectorSection(
            id: "collider",
            title: L("Collider"),
            fields: fields
        )
    }

    private func colliderCenterBinding(
        for entity: EntityID,
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.shape.center[keyPath: axis] ?? 0
            },
            set: { [self] next in
                guard var collider = scene.component(Collider.self, for: entity),
                      collider.shape.center[keyPath: axis] != next else { return }
                var center = collider.shape.center
                center[keyPath: axis] = next
                collider.shape = collider.shape.replacingCenter(with: center)
                _ = applySceneTransaction(intentVerb: "scene.set_collider_center",
                                          summary: "Update collider center",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCollider(entityID: entity.rawValue, collider: collider)])
            }
        )
    }

    private func colliderTriggerBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.isTrigger ?? false
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.isTrigger != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_trigger",
                                          summary: "Update collider trigger flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderTrigger(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderShapeKindBinding(for entity: EntityID) -> Binding<ColliderShapeKind> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.shape.kind ?? .box
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.shape.kind != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_shape_type",
                                          summary: "Update collider shape type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeType(entityID: entity.rawValue, kind: next)])
            }
        )
    }

    private func colliderBoxHalfExtentsBinding(for entity: EntityID,
                                                axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .box(he, _) = collider.shape {
                    return he[keyPath: axis]
                }
                return 0.5
            },
            set: { [self] next in
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .box(he, _) = collider.shape,
                      he[keyPath: axis] != next else { return }
                var newHE = he
                newHE[keyPath: axis] = max(0.01, next)
                _ = applySceneTransaction(intentVerb: "scene.set_collider_box_extents",
                                          summary: "Update collider box extents",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeBoxHalfExtents(entityID: entity.rawValue,
                                                                                      halfExtents: newHE)])
            }
        )
    }

    private func colliderSphereRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .sphere(r, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .sphere(r, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_sphere_radius",
                                          summary: "Update collider sphere radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeSphereRadius(entityID: entity.rawValue,
                                                                                    radius: clamped)])
            }
        )
    }

    private func colliderCapsuleRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(r, _, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(r, _, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_radius",
                                          summary: "Update collider capsule radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleRadius(entityID: entity.rawValue,
                                                                                     radius: clamped)])
            }
        )
    }

    private func colliderCapsuleHalfHeightBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(_, hh, _) = collider.shape {
                    return hh
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(_, hh, _) = collider.shape,
                      hh != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_half_height",
                                          summary: "Update collider capsule half height",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleHalfHeight(entityID: entity.rawValue,
                                                                                         halfHeight: clamped)])
            }
        )
    }

    private func colliderCylinderRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .cylinder(radius, _, _) = collider.shape else { return 0.5 }
                return radius
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard var collider = scene.component(Collider.self, for: entity),
                      case let .cylinder(radius, halfHeight, center) = collider.shape,
                      radius != clamped else { return }
                collider.shape = .cylinder(radius: clamped, halfHeight: halfHeight, center: center)
                guard scene.setComponent(collider, for: entity) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func colliderCylinderHalfHeightBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .cylinder(_, halfHeight, _) = collider.shape else { return 0.5 }
                return halfHeight
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard var collider = scene.component(Collider.self, for: entity),
                      case let .cylinder(radius, halfHeight, center) = collider.shape,
                      halfHeight != clamped else { return }
                collider.shape = .cylinder(radius: radius, halfHeight: clamped, center: center)
                guard scene.setComponent(collider, for: entity) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func colliderShapeInstancesBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let collider = scene.component(Collider.self, for: entity) else { return "[]" }
                let encoded = collider.shapes.map(EditorSceneManifestColliderShapeInstance.init)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard let data = try? encoder.encode(encoded) else { return "[]" }
                return String(decoding: data, as: UTF8.self)
            },
            set: { [self] text in
                guard let data = text.data(using: .utf8),
                      let encoded = try? JSONDecoder().decode(
                        [EditorSceneManifestColliderShapeInstance].self,
                        from: data
                      ),
                      !encoded.isEmpty,
                      var collider = scene.component(Collider.self, for: entity)
                else { return }
                let shapes = encoded.map(\.instance)
                guard shapes != collider.shapes else { return }
                collider.shapes = shapes
                guard scene.setComponent(collider, for: entity) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func colliderShapeInstanceListBinding(
        for entity: EntityID
    ) -> Binding<[ColliderShapeInstance]> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.shapes ?? []
            },
            set: { [self] shapes in
                guard !shapes.isEmpty,
                      var collider = scene.component(Collider.self, for: entity),
                      collider.shapes != shapes
                else { return }
                collider.shapes = shapes
                guard scene.setComponent(collider, for: entity) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func colliderFrictionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.friction ?? 0.6
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.friction != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_friction",
                                          summary: "Update collider friction",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialFriction(entityID: entity.rawValue,
                                                                                   value: clamped)])
            }
        )
    }

    private func colliderRestitutionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.restitution ?? 0
            },
            set: { [self] next in
                let clamped = max(0, min(next, 1))
                guard scene.component(Collider.self, for: entity)?.material.restitution != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_restitution",
                                          summary: "Update collider restitution",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialRestitution(entityID: entity.rawValue,
                                                                                      value: clamped)])
            }
        )
    }

    private func colliderDensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.density ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.density != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_density",
                                          summary: "Update collider density",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialDensity(entityID: entity.rawValue,
                                                                                  value: clamped)])
            }
        )
    }

    private func colliderLayerBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(Collider.self, for: entity)?.layerID ?? 0)
            },
            set: { [self] next in
                let clamped = UInt16(max(0, min(next, 65535)))
                guard scene.component(Collider.self, for: entity)?.layerID != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_layer",
                                          summary: "Update collider layer",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderLayer(entityID: entity.rawValue,
                                                                        layerID: clamped)])
            }
        )
    }

    private func colliderLayerMaskBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(Collider.self, for: entity)?.layerMask ?? .max)
            },
            set: { [self] next in
                let clamped = UInt16(max(0, min(next, 65535)))
                guard scene.component(Collider.self, for: entity)?.layerMask != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_layer_mask",
                                          summary: "Update collider layer mask",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderLayerMask(entityID: entity.rawValue,
                                                                            layerMask: clamped)])
            }
        )
    }
}
