import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func lightSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let light = scene.component(LightComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "type",
                label: L("Type"),
                value: .lightType(lightTypeBinding(for: entity))
            ),
            EditorInspectorField(
                id: "color",
                label: L("Color"),
                value: .color(lightColorBinding(for: entity))
            )
        ]

        switch light.type {
        case .directional:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .number(lightIntensityBinding(for: entity))
                )
            )
        case .point:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
        case .spot:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-inner-angle",
                    label: L("Inner Angle"),
                    value: .constrainedNumber(lightSpotInnerAngleBinding(for: entity),
                                              min: 0,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-outer-angle",
                    label: L("Outer Angle"),
                    value: .constrainedNumber(lightSpotOuterAngleBinding(for: entity),
                                              min: 1,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-cone-hint",
                    label: L("Cone"),
                    value: .readOnly("\(format(light.spotInnerAngleDegrees))掳 -> \(format(light.spotOuterAngleDegrees))掳")
                )
            )
        }

        return EditorInspectorSection(
            id: "light",
            title: L("Light"),
            fields: fields
        )
    }

    func cameraSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(CameraComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "camera",
            title: L("Camera"),
            fields: [
                EditorInspectorField(
                    id: "camera-active",
                    label: L("Active"),
                    value: .bool(cameraActiveBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "camera-fov",
                    label: L("Field of View"),
                    value: .constrainedNumber(cameraFOVBinding(for: entity),
                                              min: 1, max: 179, step: 1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "camera-aspect",
                    label: L("Aspect Ratio"),
                    value: .constrainedNumber(cameraAspectBinding(for: entity),
                                              min: 0.1, max: 10, step: 0.01, showsStepper: true)
                ),
            ]
        )
    }

    private func cameraActiveBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(CameraComponent.self, for: entity)?.isActive ?? false
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity),
                      cam.isActive != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_active",
                                          summary: "Update camera active",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraActive(entityID: entity.rawValue, isActive: next)])
            }
        )
    }

    /// Field of view exposed in degrees; the component stores radians.
    private func cameraFOVBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                let radians = scene.component(CameraComponent.self, for: entity)?.fovYRadians ?? (.pi / 4)
                return radians * 180 / .pi
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity) else { return }
                let currentDegrees = cam.fovYRadians * 180 / .pi
                guard abs(currentDegrees - next) > 1e-4 else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_fov",
                                          summary: "Update camera field of view",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraFOV(entityID: entity.rawValue, fovYDegrees: next)])
            }
        )
    }

    private func cameraAspectBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(CameraComponent.self, for: entity)?.aspectRatio ?? 1
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity) else { return }
                let clamped = max(0.1, min(10, next))
                guard abs(cam.aspectRatio - clamped) > 1e-4 else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_aspect_ratio",
                                          summary: "Update camera aspect ratio",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraAspectRatio(entityID: entity.rawValue,
                                                                             aspectRatio: clamped)])
            }
        )
    }

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
                                          mutations: [.setRenderMeshVisibility(entityID: entity.rawValue, isVisible: next)])
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
                                          mutations: [.setMeshColorTint(entityID: entity.rawValue, color: nextColor)])
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
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material base color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            baseColorTextureIndex: mat.baseColorTextureIndex,
                                            normalTextureIndex: mat.normalTextureIndex,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
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
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material metallic",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            baseColorTextureIndex: mat.baseColorTextureIndex,
                                            normalTextureIndex: mat.normalTextureIndex,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
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
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material roughness",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            baseColorTextureIndex: mat.baseColorTextureIndex,
                                            normalTextureIndex: mat.normalTextureIndex,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
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
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material emissive",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            baseColorTextureIndex: mat.baseColorTextureIndex,
                                            normalTextureIndex: mat.normalTextureIndex,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
            }
        )
    }

    private func lightTypeBinding(for entity: EntityID) -> Binding<LightType> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.type ?? .directional
            },
            set: { [self] next in
                guard scene.component(LightComponent.self, for: entity)?.type != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_type",
                                          summary: "Update light type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightType(entityID: entity.rawValue, type: next)])
            }
        )
    }

    private func lightColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let linear = scene.component(LightComponent.self, for: entity)?.color ?? SIMD3<Float>(1, 1, 1)
                return Color(r: linear.x, g: linear.y, b: linear.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(LightComponent.self, for: entity)?.color != nextColor else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_color",
                                          summary: "Update light color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightColor(entityID: entity.rawValue, color: nextColor)])
            }
        )
    }

    private func lightIntensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.intensity ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.intensity != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_intensity",
                                          summary: "Update light intensity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightIntensity(entityID: entity.rawValue, intensity: clamped)])
            }
        )
    }

    private func lightRangeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.range ?? 10
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.range != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_range",
                                          summary: "Update light range",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightRange(entityID: entity.rawValue, range: clamped)])
            }
        )
    }

    private func lightSpotInnerAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees ?? 20
            },
            set: { [self] next in
                let currentOuter = scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
                let clamped = max(0, min(currentOuter, next))
                guard scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_inner_angle",
                                          summary: "Update spotlight inner angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotInnerAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func lightSpotOuterAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
            },
            set: { [self] next in
                let clamped = max(1, min(179, next))
                guard scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_outer_angle",
                                          summary: "Update spotlight outer angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotOuterAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }
}
