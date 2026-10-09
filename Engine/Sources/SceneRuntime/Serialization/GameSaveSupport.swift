import Foundation
import SIMDCompat

extension SceneSerializer {
    // MARK: - GameSave destruction state

    static func serializeDestructionRuntimeSource(
        _ source: DestructionRuntimeSourceState
    ) -> [String: Any] {
        var encoded: [String: Any] = [
            "hasFractured": source.hasFractured,
            "isFullyFractured": source.isFullyFractured,
            "accumulatedDamage": source.accumulatedDamage,
            "brokenConnectionIDs": source.brokenConnectionIDs.sorted().map(Int.init),
            "releasedFragmentIDs": source.releasedFragmentIDs.sorted().map(Int.init),
        ]
        if source.hasAuthoredSourceSnapshot {
            var snapshot: [String: Any] = [
                "hasRigidBody": source.authoredRigidBody != nil,
                "hasCollider": source.authoredCollider != nil,
                "hasRenderMesh": source.authoredRenderMesh != nil,
            ]
            if let rigidBody = source.authoredRigidBody {
                snapshot["rigidbody"] = BuiltinComponentCodecs.serializeRigidBody(rigidBody)
            }
            if let collider = source.authoredCollider {
                snapshot["collider"] = BuiltinComponentCodecs.serializeCollider(collider)
            }
            if let renderMesh = source.authoredRenderMesh {
                snapshot["renderMesh"] = BuiltinComponentCodecs.serializeRenderMesh(renderMesh)
            }
            encoded["authoredSourceSnapshot"] = snapshot
        }
        return encoded
    }

    static func serializeDestructibleFragment(
        _ fragment: DestructibleFragment,
        sourceIndex: Int,
        entity: EntityID,
        runtime: DestructionRuntimeStateResource?
    ) -> [String: Any] {
        let elapsedSeconds = runtime?.elapsedSeconds ?? fragment.spawnedAtSeconds
        let ageSeconds = max(0, elapsedSeconds - fragment.spawnedAtSeconds)
        let remainingLifetime: Float
        if fragment.maximumLifetimeSeconds > 0 {
            remainingLifetime = max(
                0.000_001,
                fragment.maximumLifetimeSeconds - Float(ageSeconds)
            )
        } else {
            remainingLifetime = 0
        }

        var remainingSleepingDelay = fragment.sleepingRecycleDelaySeconds
        let sleepingSince = runtime?.sleepingSinceByFragment[entity]
        if let sleepingSince, remainingSleepingDelay > 0 {
            remainingSleepingDelay = max(
                0.000_001,
                remainingSleepingDelay - Float(max(0, elapsedSeconds - sleepingSince))
            )
        }
        return [
            "sourceEntity": sourceIndex,
            "fragmentID": Int(fragment.fragmentID),
            "remainingLifetimeSeconds": remainingLifetime,
            "remainingSleepingRecycleDelaySeconds": remainingSleepingDelay,
            "wasSleeping": sleepingSince != nil,
        ]
    }

    static func restoreDestructionRuntimeState(
        from entities: [Any],
        entityMap: [Int: EntityID],
        into scene: inout RuntimeWorld
    ) {
        var runtime = scene.resource(DestructionRuntimeStateResource.self)
            ?? DestructionRuntimeStateResource()
        var restoredRuntimeState = false

        for (index, raw) in entities.enumerated() {
            guard let entity = entityMap[index],
                  let obj = jsonToDict(raw),
                  let components = jsonToDict(obj["components"]),
                  let encoded = jsonToDict(components["destructionRuntimeSource"])
            else { continue }

            var source = DestructionRuntimeSourceState(
                hasFractured: jsonToBool(encoded["hasFractured"]) ?? false,
                isFullyFractured: jsonToBool(encoded["isFullyFractured"])
                    ?? (jsonToBool(encoded["hasFractured"]) ?? false),
                accumulatedDamage: jsonToFloat(encoded["accumulatedDamage"]) ?? 0,
                brokenConnectionIDs: Set(
                    (jsonToArray(encoded["brokenConnectionIDs"]) ?? []).compactMap {
                        jsonToInt($0).flatMap { UInt32(exactly: $0) }
                    }
                ),
                releasedFragmentIDs: Set(
                    (jsonToArray(encoded["releasedFragmentIDs"]) ?? []).compactMap {
                        jsonToInt($0).flatMap { UInt32(exactly: $0) }
                    }
                )
            )
            if let snapshot = jsonToDict(encoded["authoredSourceSnapshot"]) {
                source.hasAuthoredSourceSnapshot = true
                if jsonToBool(snapshot["hasRigidBody"]) == true,
                   let rigidBody = jsonToDict(snapshot["rigidbody"]) {
                    source.authoredRigidBody = BuiltinComponentCodecs.deserializeRigidBody(rigidBody)
                }
                if jsonToBool(snapshot["hasCollider"]) == true,
                   let collider = jsonToDict(snapshot["collider"]) {
                    source.authoredCollider = BuiltinComponentCodecs.deserializeCollider(collider)
                }
                if jsonToBool(snapshot["hasRenderMesh"]) == true,
                   let renderMesh = jsonToDict(snapshot["renderMesh"]) {
                    source.authoredRenderMesh = BuiltinComponentCodecs.deserializeRenderMesh(renderMesh)
                }
            }
            runtime.sources[entity] = source
            restoredRuntimeState = true
        }

        for (index, raw) in entities.enumerated() {
            guard let entity = entityMap[index],
                  let obj = jsonToDict(raw),
                  let components = jsonToDict(obj["components"]),
                  let encoded = jsonToDict(components["destructibleFragment"]),
                  let sourceIndex = jsonToInt(encoded["sourceEntity"]),
                  let sourceEntity = entityMap[sourceIndex],
                  let fragmentIDValue = jsonToInt(encoded["fragmentID"]),
                  let fragmentID = UInt32(exactly: fragmentIDValue)
            else { continue }

            let wasSleeping = jsonToBool(encoded["wasSleeping"]) ?? false
            _ = scene.setComponent(
                DestructibleFragment(
                    sourceEntity: sourceEntity,
                    fragmentID: fragmentID,
                    spawnedAtSeconds: runtime.elapsedSeconds,
                    maximumLifetimeSeconds: jsonToFloat(
                        encoded["remainingLifetimeSeconds"]
                    ) ?? 0,
                    sleepingRecycleDelaySeconds: jsonToFloat(
                        encoded["remainingSleepingRecycleDelaySeconds"]
                    ) ?? 0
                ),
                for: entity
            )
            if wasSleeping {
                _ = scene.updateComponent(RigidBody.self, for: entity) {
                    $0.isSleeping = true
                }
                runtime.sleepingSinceByFragment[entity] = runtime.elapsedSeconds
            }
            var source = runtime.sources[sourceEntity]
                ?? DestructionRuntimeSourceState()
            source.hasFractured = true
            runtime.sources[sourceEntity] = source
            restoredRuntimeState = true
        }

        for (index, raw) in entities.enumerated() {
            guard let entity = entityMap[index],
                  let obj = jsonToDict(raw),
                  let components = jsonToDict(obj["components"]),
                  let encoded = jsonToDict(components["destructibleRetainedFragment"]),
                  let sourceIndex = jsonToInt(encoded["sourceEntity"]),
                  let sourceEntity = entityMap[sourceIndex],
                  let fragmentIDValue = jsonToInt(encoded["fragmentID"]),
                  let fragmentID = UInt32(exactly: fragmentIDValue)
            else { continue }
            _ = scene.setComponent(
                DestructibleRetainedFragment(
                    sourceEntity: sourceEntity,
                    fragmentID: fragmentID
                ),
                for: entity
            )
            restoredRuntimeState = true
        }

        if restoredRuntimeState {
            scene.setResource(runtime)
        }
    }

}
