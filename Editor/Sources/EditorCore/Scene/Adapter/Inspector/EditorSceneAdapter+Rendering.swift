import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func renderMeshSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(RenderMeshComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "render-mesh",
            title: L("Render Mesh"),
            fields: [
                EditorInspectorField(
                    id: "mesh-visible",
                    label: L("Visible"),
                    value: .bool(renderMeshVisibilityBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mesh-color-tint",
                    label: L("Color Tint"),
                    value: .color(renderMeshColorTintBinding(for: entity))
                ),
            ]
        )
    }

    private func renderMeshVisibilityBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RenderMeshComponent.self, for: entity)?.isVisible ?? true
            },
            set: { [self] next in
                guard let mesh = scene.component(RenderMeshComponent.self, for: entity),
                      mesh.isVisible != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_mesh_visibility",
                                          summary: "Update mesh visibility",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "renderMesh", fields: ["isVisible": (next)])])
            }
        )
    }

    private func renderMeshColorTintBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let tint = scene.component(RenderMeshComponent.self, for: entity)?.colorTint ?? SIMD3<Float>(1, 1, 1)
                return Color(r: tint.x, g: tint.y, b: tint.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(RenderMeshComponent.self, for: entity)?.colorTint != nextColor else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_mesh_color",
                                          summary: "Update mesh color tint",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.componentFields(entityID: entity.rawValue, typeID: "renderMesh", fields: ["colorTint": (nextColor)])])
            }
        )
    }

    func renderMaterialSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(RenderMaterialComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "render-material",
            title: L("Render Material"),
            fields: [
                EditorInspectorField(
                    id: "mat-base-color",
                    label: L("Base Color"),
                    value: .color(renderMaterialBaseColorBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mat-metallic",
                    label: L("Metallic"),
                    value: .constrainedNumber(renderMaterialMetallicBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "mat-roughness",
                    label: L("Roughness"),
                    value: .constrainedNumber(renderMaterialRoughnessBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "mat-emissive",
                    label: L("Emissive"),
                    value: .color(renderMaterialEmissiveBinding(for: entity))
                ),
            ]
        )
    }

    private func renderMaterialBaseColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(RenderMaterialComponent.self, for: entity)?.baseColorFactor ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity) else { return }
                let nextColor = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                             max(0, min(1, next.b)), max(0, min(1, next.a)))
                guard mat.baseColorFactor != nextColor else { return }
                mat.baseColorFactor = nextColor
                _ = setComponentData(mat, for: entity)
            }
        )
    }

    private func renderMaterialMetallicBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RenderMaterialComponent.self, for: entity)?.metallicFactor ?? 0
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity),
                      mat.metallicFactor != next else { return }
                mat.metallicFactor = next
                _ = setComponentData(mat, for: entity)
            }
        )
    }

    private func renderMaterialRoughnessBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RenderMaterialComponent.self, for: entity)?.roughnessFactor ?? 1
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity),
                      mat.roughnessFactor != next else { return }
                mat.roughnessFactor = next
                _ = setComponentData(mat, for: entity)
            }
        )
    }

    private func renderMaterialEmissiveBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let e = scene.component(RenderMaterialComponent.self, for: entity)?.emissiveFactor ?? .zero
                return Color(r: e.x, g: e.y, b: e.z, a: 1)
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity) else { return }
                let nextEmissive = SIMD3<Float>(max(0, next.r), max(0, next.g), max(0, next.b))
                guard mat.emissiveFactor != nextEmissive else { return }
                mat.emissiveFactor = nextEmissive
                _ = setComponentData(mat, for: entity)
            }
        )
    }

}
