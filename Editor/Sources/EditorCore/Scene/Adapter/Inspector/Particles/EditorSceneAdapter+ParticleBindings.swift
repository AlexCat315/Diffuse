import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func particleGPUStatusLabel(for entity: EntityID) -> String {
        guard let emitter = scene.component(ParticleEmitter.self, for: entity) else {
            return L("No emitter")
        }
        let plan = emitter.gpuSimulationPlan
        switch plan.status {
        case .disabled:
            return L("CPU")
        case .supported:
            return "\(L("Supported")) (\(plan.dispatchWorkgroups)x\(plan.workgroupSize))"
        case .fallbackToCPU:
            return "\(L("CPU fallback")): \(particleGPUUnsupportedReasonList(plan.unsupportedReasons))"
        case .requiredButUnsupported:
            return "\(L("Unsupported")): \(particleGPUUnsupportedReasonList(plan.unsupportedReasons))"
        }
    }

    private func particleGPUUnsupportedReasonList(
        _ reasons: [ParticleGPUSimulationUnsupportedReason]
    ) -> String {
        guard !reasons.isEmpty else { return L("None") }
        return reasons.map(particleGPUUnsupportedReasonLabel).joined(separator: ", ")
    }

    private func particleGPUUnsupportedReasonLabel(
        _ reason: ParticleGPUSimulationUnsupportedReason
    ) -> String {
        switch reason {
        case .backendCPU:
            return L("CPU backend")
        case .noParticleCapacity:
            return L("no capacity")
        case .eventSubEmitters:
            return L("sub-emitters")
        case .distanceEmission:
            return L("distance emission")
        case .noise:
            return L("noise")
        case .forceFields:
            return L("force fields")
        case .collisions:
            return L("collisions")
        case .angularVelocity:
            return L("angular velocity")
        }
    }

    /// Applies `mutate` to a copy of the emitter and submits it as a whole-component update.
    private func updateParticleEmitter(_ entity: EntityID, summary: String,
                                       _ mutate: (inout ParticleEmitter) -> Void) {
        guard var emitter = scene.component(ParticleEmitter.self, for: entity) else { return }
        mutate(&emitter)
        _ = applySceneTransaction(intentVerb: "scene.set_particle_emitter",
                                  summary: summary,
                                  targetRawIDs: [entity.rawValue],
                                  mutations: [.setParticleEmitter(entityID: entity.rawValue, emitter: emitter)])
    }

    func particleModuleStackBinding(for entity: EntityID) -> Binding<ParticleModuleStack> {
        Binding(
            get: { [self] in
                scene.component(ParticleEmitter.self, for: entity)?.moduleStack ?? ParticleModuleStack()
            },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.moduleStack != next else { return }
                updateParticleEmitter(entity, summary: "Update particle module stack") {
                    $0.apply(next)
                }
            }
        )
    }

    func particleBoolBinding(for entity: EntityID,
                                     _ keyPath: WritableKeyPath<ParticleEmitter, Bool>,
                                     summary: String) -> Binding<Bool> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? false },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    func particleFloatBinding(for entity: EntityID,
                                      _ keyPath: WritableKeyPath<ParticleEmitter, Float>,
                                      summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    func particleMaxBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?.settings.emission.maxParticles ?? 0) },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.emission.maxParticles != value else { return }
                updateParticleEmitter(entity, summary: "Update max particles") { $0.settings.emission.maxParticles = value }
            }
        )
    }

    func particleIntBinding(for entity: EntityID,
                                    _ keyPath: WritableKeyPath<ParticleEmitter, Int>,
                                    summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? 0) },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != value else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = value }
            }
        )
    }

    func particleClampedIntBinding(for entity: EntityID,
                                           _ keyPath: WritableKeyPath<ParticleEmitter, Int>,
                                           min minimum: Int,
                                           max maximum: Int,
                                           summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? minimum) },
            set: { [self] next in
                let lower = min(minimum, maximum)
                let upper = max(minimum, maximum)
                let value = Swift.max(lower, Swift.min(upper, Int(next.rounded())))
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != value else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = value }
            }
        )
    }

    func particleShapeBinding(for entity: EntityID) -> Binding<ParticleEmissionShape> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.shape.emissionShape ?? .sphere },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.shape.emissionShape != next else { return }
                updateParticleEmitter(entity, summary: "Update particle emission shape") { $0.settings.shape.emissionShape = next }
            }
        )
    }

    func particleBoxExtentsBinding(for entity: EntityID, axis: Int) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.shape.boxHalfExtents[axis] ?? 0 },
            set: { [self] next in
                let value = max(0, next)
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.shape.boxHalfExtents[axis] != value else { return }
                updateParticleEmitter(entity, summary: "Update particle box extents") { $0.settings.shape.boxHalfExtents[axis] = value }
            }
        )
    }

    func particleCollisionModeBinding(for entity: EntityID) -> Binding<ParticleCollisionMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.collision.collisionMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.collision.collisionMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle collision mode") { $0.settings.collision.collisionMode = next }
            }
        )
    }

    func particleForceModeBinding(for entity: EntityID) -> Binding<ParticleForceMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.forces.forceMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.forces.forceMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle force mode") { $0.settings.forces.forceMode = next }
            }
        )
    }

    func particleVectorFieldModeBinding(for entity: EntityID) -> Binding<ParticleVectorFieldMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.forces.vectorFieldMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.forces.vectorFieldMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle vector field mode") {
                    $0.settings.forces.vectorFieldMode = next
                }
            }
        )
    }

    func particleSubEmitterTriggerBinding(for entity: EntityID) -> Binding<ParticleSubEmitterTrigger> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.subEmitters.legacyTrigger ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.subEmitters.legacyTrigger != next else { return }
                updateParticleEmitter(entity, summary: "Update sub-emitter trigger") { $0.settings.subEmitters.legacyTrigger = next }
            }
        )
    }

    func particleSubEmittersBinding(for entity: EntityID) -> Binding<[ParticleSubEmitter]> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.subEmitters.rules ?? [] },
            set: { [self] next in
                let sanitized = next.map(sanitizedParticleSubEmitter)
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.subEmitters.rules != sanitized else { return }
                updateParticleEmitter(entity, summary: "Update particle sub-emitters") {
                    $0.settings.subEmitters.rules = sanitized
                }
            }
        )
    }

    private func sanitizedParticleSubEmitter(_ rule: ParticleSubEmitter) -> ParticleSubEmitter {
        ParticleSubEmitter(trigger: rule.trigger,
                           burstCount: rule.burstCount,
                           probability: rule.probability,
                           maxDepth: rule.maxDepth,
                           inheritVelocity: rule.inheritVelocity,
                           lifetime: rule.lifetime,
                           startVelocity: rule.startVelocity,
                           velocityRandomness: rule.velocityRandomness,
                           startSize: rule.startSize,
                           endSize: rule.endSize,
                           startColor: rule.startColor,
                           endColor: rule.endColor)
    }

    func particleVectorBinding(for entity: EntityID,
                                       keyPath: WritableKeyPath<ParticleEmitter, SIMD3<Float>>,
                                       axis: Int,
                                       summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath][axis] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath][axis] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath][axis] = next }
            }
        )
    }

    func particleSimulationSpaceBinding(for entity: EntityID) -> Binding<ParticleSimulationSpace> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.gpuSimulation.simulationSpace ?? .local },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.gpuSimulation.simulationSpace != next else { return }
                updateParticleEmitter(entity, summary: "Update particle simulation space") { $0.settings.gpuSimulation.simulationSpace = next }
            }
        )
    }

    func particleSimulationBackendBinding(for entity: EntityID) -> Binding<ParticleSimulationBackend> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.gpuSimulation.simulationBackend ?? .cpu },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.gpuSimulation.simulationBackend != next else { return }
                updateParticleEmitter(entity, summary: "Update particle simulation backend") {
                    $0.settings.gpuSimulation.simulationBackend = next
                }
            }
        )
    }

    func particleCurveBinding(for entity: EntityID,
                                      _ keyPath: WritableKeyPath<ParticleEmitter, ParticleCurve>,
                                      summary: String) -> Binding<ParticleCurve> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? .linear },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    func particleBlendModeBinding(for entity: EntityID) -> Binding<ParticleBlendMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.appearance.blendMode ?? .alpha },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.appearance.blendMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle blend mode") { $0.settings.appearance.blendMode = next }
            }
        )
    }

    func particleRenderModeBinding(for entity: EntityID) -> Binding<ParticleRenderMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderMode ?? .billboard },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render mode") { $0.settings.renderer.renderMode = next }
            }
        )
    }

    func particleSortModeBinding(for entity: EntityID) -> Binding<ParticleSortMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.sortMode ?? .distanceDescending },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.sortMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle sort mode") { $0.settings.renderer.sortMode = next }
            }
        )
    }

    func particleTextureSheetPlaybackModeBinding(
        for entity: EntityID
    ) -> Binding<ParticleTextureSheetPlaybackMode> {
        Binding(
            get: {
                [self] in scene.component(ParticleEmitter.self,
                                           for: entity)?.settings.textureSheet.playbackMode ?? .automatic
            },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self,
                                      for: entity)?.settings.textureSheet.playbackMode != next else { return }
                updateParticleEmitter(entity, summary: "Update texture sheet playback") {
                    $0.settings.textureSheet.playbackMode = next
                }
            }
        )
    }

    func particleRenderAlignmentBinding(for entity: EntityID) -> Binding<ParticleRenderAlignment> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderAlignment ?? .billboard },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderAlignment != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render alignment") { $0.settings.renderer.renderAlignment = next }
            }
        )
    }

    func particleRenderBoundsModeBinding(for entity: EntityID) -> Binding<ParticleRenderBoundsMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderBoundsMode ?? .disabled },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.renderer.renderBoundsMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render bounds mode") {
                    $0.settings.renderer.renderBoundsMode = next
                }
            }
        )
    }

    func particleTextureAssetBinding(for entity: EntityID) -> Binding<EditorInspectorAssetRef?> {
        Binding(
            get: { [self] in
                guard let emitter = scene.component(ParticleEmitter.self, for: entity) else { return nil }
                if let assetID = emitter.settings.textureSheet.textureAssetID,
                   let asset = EditorAssetCatalog.asset(for: assetID) {
                    return EditorInspectorAssetRef(id: asset.id,
                                                   name: asset.name,
                                                   subtitle: asset.relativePath,
                                                   kind: asset.kind.sceneKindLabel,
                                                   previewPath: asset.kind.isTexture ? asset.absolutePath : nil)
                }
                if let texturePath = emitter.settings.textureSheet.texturePath, !texturePath.isEmpty {
                    let url = URL(fileURLWithPath: texturePath)
                    return EditorInspectorAssetRef(id: emitter.settings.textureSheet.textureAssetID ?? texturePath,
                                                   name: url.deletingPathExtension().lastPathComponent,
                                                   subtitle: texturePath,
                                                   kind: ImportableAssetKind.png.sceneKindLabel,
                                                   previewPath: texturePath)
                }
                return nil
            },
            set: { [self] next in
                guard let current = scene.component(ParticleEmitter.self, for: entity) else { return }
                let resolved: (assetID: String?, path: String?)
                if let next {
                    if let asset = EditorAssetCatalog.asset(for: next.id),
                       asset.kind.isTexture {
                        resolved = (asset.id, asset.absolutePath)
                    } else if next.kind == ImportableAssetKind.png.sceneKindLabel {
                        let path = next.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                        resolved = (next.id, path?.isEmpty == false ? path : nil)
                    } else {
                        return
                    }
                } else {
                    resolved = (nil, nil)
                }
                guard current.settings.textureSheet.textureAssetID != resolved.assetID || current.settings.textureSheet.texturePath != resolved.path else { return }
                updateParticleEmitter(entity, summary: "Update particle texture") {
                    $0.settings.textureSheet.textureAssetID = resolved.assetID
                    $0.settings.textureSheet.texturePath = resolved.path
                }
            }
        )
    }

    func particleGravityBinding(for entity: EntityID, axis: Int) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.settings.forces.gravity[axis] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.settings.forces.gravity[axis] != next else { return }
                updateParticleEmitter(entity, summary: "Update particle gravity") { $0.settings.forces.gravity[axis] = next }
            }
        )
    }

    func particleSubEmitterColorBinding(for entity: EntityID, isStart: Bool) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.settings.subEmitters.legacyStartColor : $0.settings.subEmitters.legacyEndColor }
                    ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                let v = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                     max(0, min(1, next.b)), max(0, min(1, next.a)))
                let current = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.settings.subEmitters.legacyStartColor : $0.settings.subEmitters.legacyEndColor }
                guard current != v else { return }
                updateParticleEmitter(entity, summary: "Update sub-emitter color") {
                    if isStart { $0.settings.subEmitters.legacyStartColor = v } else { $0.settings.subEmitters.legacyEndColor = v }
                }
            }
        )
    }

    func particleColorBinding(for entity: EntityID, isStart: Bool) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.settings.appearance.startColor : $0.settings.appearance.endColor } ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                let v = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                     max(0, min(1, next.b)), max(0, min(1, next.a)))
                let current = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.settings.appearance.startColor : $0.settings.appearance.endColor }
                guard current != v else { return }
                updateParticleEmitter(entity, summary: "Update particle color") {
                    if isStart { $0.settings.appearance.startColor = v } else { $0.settings.appearance.endColor = v }
                }
            }
        )
    }
}
