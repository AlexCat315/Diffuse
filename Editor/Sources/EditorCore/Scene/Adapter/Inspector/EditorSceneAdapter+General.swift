import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func generalSection(for entity: EntityID) -> EditorInspectorSection {
        EditorInspectorSection(
            id: "general",
            title: L("General"),
            fields: [
                EditorInspectorField(
                    id: "name",
                    label: L("Name"),
                    value: .text(nameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "kind",
                    label: L("Kind"),
                    value: .readOnly(displayKind(for: entity))
                ),
                EditorInspectorField(
                    id: "entity-id",
                    label: L("Entity ID"),
                    value: .readOnly(String(entity.rawValue))
                ),
            ]
        )
    }

    func hierarchySection(for entity: EntityID) -> EditorInspectorSection {
        let parentLabel: String
        if let parent = scene.parent(of: entity) {
            parentLabel = displayName(for: parent)
        } else {
            parentLabel = L("Root")
        }

        return EditorInspectorSection(
            id: "hierarchy",
            title: L("Hierarchy"),
            fields: [
                EditorInspectorField(
                    id: "parent",
                    label: L("Parent"),
                    value: .readOnly(parentLabel)
                ),
                EditorInspectorField(
                    id: "children",
                    label: L("Children"),
                    value: .readOnly(String(scene.children(of: entity).count))
                ),
            ]
        )
    }

    func transformSection(for entity: EntityID) -> EditorInspectorSection? {
        let local = scene.localTransform(for: entity)
        let world = scene.worldTransform(for: entity)
        guard local != nil || world != nil else { return nil }

        var fields: [EditorInspectorField] = []
        if local != nil {
            fields.append(
                EditorInspectorField(
                    id: "local-position",
                    label: L("Local Position"),
                    value: .vector3(x: localPositionBinding(for: entity, axis: \.x),
                                    y: localPositionBinding(for: entity, axis: \.y),
                                    z: localPositionBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-rotation",
                    label: L("Rotation"),
                    value: .vector3(x: localRotationBinding(for: entity, axis: \.x),
                                    y: localRotationBinding(for: entity, axis: \.y),
                                    z: localRotationBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-scale",
                    label: L("Scale"),
                    value: .vector3(x: localScaleBinding(for: entity, axis: \.x),
                                    y: localScaleBinding(for: entity, axis: \.y),
                                    z: localScaleBinding(for: entity, axis: \.z))
                )
            )
        }
        if world != nil {
            let displayed = entityWorldPosition(entity.rawValue) ?? world!.translation
            fields.append(
                EditorInspectorField(
                    id: "world-position",
                    label: L("World Position"),
                    value: .readOnly(format(displayed))
                )
            )
        }

        return EditorInspectorSection(id: "transform", title: L("Transform"), fields: fields)
    }

    private func nameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
            },
            set: { [self] next in
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? fallbackName(for: entity) : trimmed
                guard scene.component(SceneNameComponent.self, for: entity)?.value != value else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_name",
                                          summary: "Rename entity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setSceneName(entityID: entity.rawValue, value: value)])
            }
        )
    }

    // MARK: - Transform bindings

    private func localPositionBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let t = scene.localTransform(for: entity)?.translation ?? .zero
                return t[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                var translation = local.translation
                guard translation[keyPath: axis] != next else { return }
                translation[keyPath: axis] = next
                local.matrix.columns.3 = SIMD4<Float>(translation, 1)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity translation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localScaleBinding(for entity: EntityID,
                                   axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (_, scale) = decomposeRotationScale(m)
                return scale[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (rot, _) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                var scale = decomposeRotationScale(local.matrix).1
                guard scale[keyPath: axis] != next else { return }
                scale[keyPath: axis] = next
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localRotationBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (rot, _) = decomposeRotationScale(m)
                let euler = eulerXYZFromMatrix(rot)
                let deg = euler * (180.0 / .pi)
                return deg[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (_, scale) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                let currentDegrees = eulerXYZFromMatrix(decomposeRotationScale(local.matrix).0) * (180.0 / .pi)
                guard currentDegrees[keyPath: axis] != next else { return }
                var degrees = currentDegrees
                degrees[keyPath: axis] = next
                let radians = degrees * (.pi / 180.0)
                let rot = matrixFromEulerXYZ(radians)
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity rotation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }
}
