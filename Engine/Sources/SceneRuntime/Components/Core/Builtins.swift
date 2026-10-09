import SIMDCompat

public extension ComponentRegistry {
    /// Creates the built-in set for a new world. Module codecs are added locally.
    static var builtIn: ComponentRegistry {
        var registry = ComponentRegistry()
        registry.register(ComponentSchema(LocalTransform.self, typeID: "localTransform", displayName: "Transform", category: .rendering,
            encode: BuiltinComponentCodecs.serializeLocalTransform, decode: BuiltinComponentCodecs.deserializeLocalTransform,
            makeDefault: { entity, world in _ = world.setLocalTransform(.identity, for: entity) },
            configure: { $0.isStructural = true; $0.isUserAddable = false }))
        registry.register(ComponentSchema(RigidBody.self, typeID: "rigidbody", displayName: "Rigid Body", category: .physics,
            encode: { world, entity, context in
                let component: RigidBody? = BuiltinComponentCodecs.authoredComponent(
                    RigidBody.self, for: entity, in: world, context: context, snapshot: { $0.authoredRigidBody })
                return component.map { ComponentValue(jsonObject: BuiltinComponentCodecs.serializeRigidBody($0)) }
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue else { return }
                _ = world.setComponent(BuiltinComponentCodecs.deserializeRigidBody(dictionary), for: entity)
            }, makeDefault: { entity, world in
                _ = world.setComponent(BuiltinComponentCodecs.deserializeRigidBody([:]), for: entity)
            }, configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(Collider.self, typeID: "collider", displayName: "Collider", category: .physics,
            encode: { world, entity, context in
                let component: Collider? = BuiltinComponentCodecs.authoredComponent(
                    Collider.self, for: entity, in: world, context: context, snapshot: { $0.authoredCollider })
                return component.map { ComponentValue(jsonObject: BuiltinComponentCodecs.serializeCollider($0)) }
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue else { return }
                _ = world.setComponent(BuiltinComponentCodecs.deserializeCollider(dictionary), for: entity)
            }, makeDefault: { entity, world in
                _ = world.setComponent(BuiltinComponentCodecs.deserializeCollider([:]), for: entity)
            }, configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(CharacterController.self, typeID: "characterController", displayName: "Character Controller", category: .gameplay,
            encode: BuiltinComponentCodecs.serializeCharacterController, decode: BuiltinComponentCodecs.deserializeCharacterController,
            configure: { $0.requires = ["localTransform"]; $0.inspection = .characterController }))
        registry.register(ComponentSchema(Vehicle.self, typeID: "vehicle", displayName: "Vehicle", category: .gameplay,
            encode: BuiltinComponentCodecs.serializeVehicle, decode: BuiltinComponentCodecs.deserializeVehicle,
            configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(SoftBody.self, typeID: "softBody", displayName: "Soft Body", category: .physics,
            encode: BuiltinComponentCodecs.serializeSoftBody, decode: BuiltinComponentCodecs.deserializeSoftBody,
            configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(Cloth.self, typeID: "cloth", displayName: "Cloth", category: .physics,
            encode: BuiltinComponentCodecs.serializeCloth, decode: BuiltinComponentCodecs.deserializeCloth,
            makeDefault: { entity, world in _ = world.setComponent(Cloth.fixedTopEdge(), for: entity) },
            configure: { $0.requires = ["localTransform"]; $0.incompatibleWith = ["softBodyMesh"] }))
        registry.register(ComponentSchema(SoftBodyMesh.self, typeID: "softBodyMesh", displayName: "Soft Body Mesh", category: .physics,
            encode: BuiltinComponentCodecs.serializeSoftBodyMesh, decode: BuiltinComponentCodecs.deserializeSoftBodyMesh,
            makeDefault: { entity, world in
                let resourceID = world.component(AssetReferenceComponent.self, for: entity).map { "meshIndex:\($0.meshIndex)" }
                _ = world.setComponent(SoftBodyMesh(resourceID: resourceID), for: entity)
            }, configure: { $0.requires = ["localTransform"]; $0.incompatibleWith = ["cloth"] }))
        registry.register(ComponentSchema(Destructible.self, typeID: "destructible", displayName: "Destructible", category: .physics,
            encode: BuiltinComponentCodecs.serializeDestructible, decode: BuiltinComponentCodecs.deserializeDestructible,
            configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(RenderMeshComponent.self, typeID: "renderMesh", displayName: "Render Mesh", category: .rendering,
            encode: { world, entity, context in
                let component: RenderMeshComponent? = BuiltinComponentCodecs.authoredComponent(
                    RenderMeshComponent.self, for: entity, in: world, context: context, snapshot: { $0.authoredRenderMesh })
                return component.map { ComponentValue(jsonObject: BuiltinComponentCodecs.serializeRenderMesh($0)) }
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue else { return }
                _ = world.setComponent(BuiltinComponentCodecs.deserializeRenderMesh(dictionary), for: entity)
            }, makeDefault: { entity, world in
                _ = world.setComponent(BuiltinComponentCodecs.deserializeRenderMesh([:]), for: entity)
            }, configure: { $0.requires = ["localTransform"] }))
        registry.register(ComponentSchema(CameraComponent.self, typeID: "camera", displayName: "Camera", category: .rendering,
            encode: BuiltinComponentCodecs.serializeCamera, decode: BuiltinComponentCodecs.deserializeCamera,
            makeDefault: { entity, world in _ = world.setComponent(CameraComponent(isActive: false), for: entity) },
            configure: { schema in
                schema.requires = ["localTransform"]
                schema.inspection = .camera
                schema.afterDuplicate = { entity, world in
                    _ = world.updateComponent(CameraComponent.self, for: entity) { $0.isActive = false }
                }
            }))
        registry.register(ComponentSchema(LightComponent.self, typeID: "light", displayName: "Light", category: .rendering,
            encode: BuiltinComponentCodecs.serializeLight, decode: BuiltinComponentCodecs.deserializeLight,
            configure: { $0.requires = ["localTransform"]; $0.inspection = .light }))
        registry.register(ComponentSchema(AudioSource.self, typeID: "audioSource", displayName: "Audio Source", category: .audio,
            encode: BuiltinComponentCodecs.serializeAudioSource, decode: BuiltinComponentCodecs.deserializeAudioSource,
            configure: { $0.requires = ["localTransform"]; $0.inspection = .audioSource }))
        registry.register(ComponentSchema(AudioListener.self, typeID: "audioListener", displayName: "Audio Listener", category: .audio,
            encode: BuiltinComponentCodecs.serializeAudioListener, decode: BuiltinComponentCodecs.deserializeAudioListener,
            configure: { $0.requires = ["localTransform"]; $0.inspection = .audioListener }))
        registry.register(ComponentSchema(RenderMaterialComponent.self, typeID: "renderMaterial", displayName: "Render Material", category: .rendering,
            encode: BuiltinComponentCodecs.serializeRenderMaterial, decode: BuiltinComponentCodecs.deserializeRenderMaterial))
        registry.register(ComponentSchema(AssetReferenceComponent.self, typeID: "assetReference", displayName: "Asset Reference", category: .assets,
            encode: BuiltinComponentCodecs.serializeAssetReference, decode: BuiltinComponentCodecs.deserializeAssetReference,
            configure: { $0.isUserAddable = false; $0.inspection.isReadOnly = true }))
        registry.register(ComponentSchema(AnimationPlayer.self, typeID: "animationPlayer", displayName: "Animation Player", category: .animation,
            encode: BuiltinComponentCodecs.serializeAnimationPlayer, decode: BuiltinComponentCodecs.deserializeAnimationPlayer))
        registry.register(ComponentSchema(AnimationGraphPlayer.self, typeID: "animationGraphPlayer", displayName: "Animation Graph", category: .animation,
            encode: BuiltinComponentCodecs.serializeAnimationGraphPlayer, decode: BuiltinComponentCodecs.deserializeAnimationGraphPlayer,
            makeDefault: { entity, world in
                _ = world.setComponent(AnimationGraphPlayer(graph: AnimationGraph(stateMachine:
                    AnimationStateMachine(initialState: "Default", states: [AnimationState(name: "Default", motion: .clip(nil))]))), for: entity)
            }))
        registry.register(ComponentSchema(ParticleEmitter.self, typeID: "particleEmitter", displayName: "Particle Emitter", category: .rendering,
            encode: BuiltinComponentCodecs.serializeParticleEmitter, decode: BuiltinComponentCodecs.deserializeParticleEmitter,
            configure: { schema in
                schema.requires = ["localTransform"]
                schema.merge = { previous, changes in
                    let merged = try previous.merging(changes)
                    guard let dictionary = merged.objectValue,
                          let fields = changes.objectValue, fields["settings"] != nil,
                          fields["moduleStack"] == nil,
                          let settings = decodeJSONValue(dictionary["settings"], as: ParticleEmitterSettings.self),
                          let original = previous.objectValue else { return merged }
                    var emitter = BuiltinComponentCodecs.deserializeParticleEmitter(original)
                    emitter.settings = settings
                    emitter.settings.normalize()
                    return ComponentValue(jsonObject: BuiltinComponentCodecs.serializeParticleEmitter(emitter))
                }
                schema.applyEdit = { value, entity, context, world in
                    guard let dictionary = value.objectValue else { return }
                    var edited = BuiltinComponentCodecs.deserializeParticleEmitter(dictionary)
                    if let previous = world.component(ParticleEmitter.self, for: entity),
                       previous.settings.emission.seed == edited.settings.emission.seed {
                        edited.runtime = previous.runtime
                    }
                    _ = world.setComponent(edited, for: entity)
                }
            }))
        registry.register(ComponentSchema(Constraint.self, typeID: "constraint", displayName: "Constraint", category: .physics,
            encode: { world, entity, context in
                guard let value = world.component(Constraint.self, for: entity),
                      let a = context.entityIndexMap[value.entityA], let b = context.entityIndexMap[value.entityB] else { return nil }
                return ComponentValue(jsonObject: BuiltinComponentCodecs.serializeConstraint(value, entityA: a, entityB: b))
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue,
                      let ai = jsonToInt(dictionary["entityA"]), let bi = jsonToInt(dictionary["entityB"]),
                      let a = context.entityMap[ai], let b = context.entityMap[bi] else { return }
                _ = world.setComponent(BuiltinComponentCodecs.deserializeConstraint(dictionary, entityA: a, entityB: b), for: entity)
            }, makeDefault: { _, _ in }, configure: { $0.isUserAddable = false; $0.inspection = .constraint }))
        registry.register(ComponentSchema(Ragdoll.self, typeID: "ragdoll", displayName: "Ragdoll", category: .physics,
            encode: { world, entity, context in
                world.component(Ragdoll.self, for: entity).map {
                    ComponentValue(jsonObject: BuiltinComponentCodecs.serializeRagdoll($0, entityIndexMap: context.entityIndexMap))
                }
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue else { return }
                _ = world.setComponent(BuiltinComponentCodecs.deserializeRagdoll(dictionary, entityMap: context.entityMap), for: entity)
            }, makeDefault: { entity, world in _ = world.setComponent(Ragdoll(), for: entity) }))
        return registry
    }
}

extension BuiltinComponentCodecs {
    static func authoredComponent<Component: RuntimeComponent>(
        _ type: Component.Type, for entity: EntityID, in world: RuntimeWorld,
        context: ComponentEncodeContext, snapshot: (DestructionRuntimeSourceState) -> Component?
    ) -> Component? {
        if context.purpose == .authored,
           let source = world.resource(DestructionRuntimeStateResource.self)?.sources[entity],
           source.hasAuthoredSourceSnapshot {
            return snapshot(source)
        }
        return world.component(type, for: entity)
    }
}
