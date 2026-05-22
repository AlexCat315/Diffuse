import Foundation
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public func currentRenderCamera() -> RenderCamera {
        scene.extractedRenderScene?.scene.camera ?? RenderCamera.fallbackPerspective
    }

    @discardableResult
    public func tickScene(deltaTime: Double = 0) -> Bool {
        _ = scene.tick(deltaTime: deltaTime)
        tickAnimationRuntime(deltaTime: deltaTime)
        return true
    }

    private func tickAnimationRuntime(deltaTime: Double) {
        scene.runScriptDriver(animationRuntime, deltaTime: deltaTime)
    }

    public func currentJointPaletteMap() -> JointPaletteMap {
        scene.resource(JointPaletteMap.self) ?? JointPaletteMap()
    }

    public func currentRenderScene() -> RenderScene {
        scene.renderScene
    }

    public func entityWorldPosition(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.translation
    }

    public func entityWorldMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.matrix
    }

    public func entityLocalTranslation(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        guard let local = scene.localTransform(for: entity) else { return nil }
        return local.translation
    }

    public func setEntityLocalTranslation(_ rawID: UInt64, to value: SIMD3<Float>) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix.columns.3 = SIMD4<Float>(value.x, value.y, value.z, 1)
        _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                  summary: "Update entity translation",
                                  targetRawIDs: [rawID],
                                  mutations: [.setLocalTransform(entityID: rawID, transform: local)])
    }

    public func entityLocalMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.localTransform(for: entity)?.matrix
    }

    public func entityParentWorldMatrix(_ rawID: UInt64) -> simd_float4x4 {
        guard let entity = makeEntityID(rawID),
              let parent = scene.parent(of: entity),
              let parentWorld = scene.worldTransform(for: parent)
        else {
            return matrix_identity_float4x4
        }
        return parentWorld.matrix
    }

    public func entityHasAncestor(_ rawID: UInt64, in candidateRawIDs: Set<UInt64>) -> Bool {
        guard var current = makeEntityID(rawID).flatMap({ scene.parent(of: $0) }) else {
            return false
        }
        while true {
            if candidateRawIDs.contains(current.rawValue) {
                return true
            }
            guard let parent = scene.parent(of: current) else {
                return false
            }
            current = parent
        }
    }

    public func setEntityLocalMatrix(_ rawID: UInt64, to matrix: simd_float4x4) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix = matrix
        _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                  summary: "Update entity transform",
                                  targetRawIDs: [rawID],
                                  mutations: [.setLocalTransform(entityID: rawID, transform: local)])
    }

    private func makeEntityID(_ rawID: UInt64) -> EntityID? {
        EntityID(
            index: UInt32(rawID & 0xFFFF_FFFF),
            generation: UInt32(rawID >> 32)
        )
    }
}
