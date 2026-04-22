import Foundation
import SceneRuntime
import simd

extension EditorSceneAdapter {
    /// 在场景里生成一个新实体并立即可见，返回 raw entity id。
    /// 调用方一般紧接着把返回的 id 写回 store 作为新的选中态。
    @discardableResult
    public func spawnEntity(from asset: EditorAsset,
                            at position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> UInt64? {
        let entity = scene.createEntity()
        let label = uniqueDisplayName(base: asset.name)
        _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
        _ = scene.setComponent(SceneKindComponent(value: asset.kind.sceneKindLabel), for: entity)

        let translation = matrix_identity_float4x4.withTranslation(position)
        _ = scene.setLocalTransform(LocalTransform(matrix: translation), for: entity)

        switch asset.kind {
        case .cube:
            _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        case .sphere:
            _ = scene.setComponent(RenderMeshComponent(meshIndex: 1), for: entity)
        case .plane:
            _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        case .pointLight, .directionalLight, .camera, .empty:
            break
        }

        if asset.kind == .camera {
            _ = scene.setComponent(
                CameraComponent(target: position + SIMD3<Float>(0, 0, -1), isActive: false),
                for: entity
            )
        }

        scene.propagateTransforms()
        publishRevisionAfterSpawn()
        return entity.rawValue
    }

    private func uniqueDisplayName(base: String) -> String {
        let existing: Set<String> = Set(scene.entities().compactMap {
            scene.component(SceneNameComponent.self, for: $0)?.value
        })
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    /// `publishRevision` 在适配器内部是 private；这里复用它的副作用通知。
    fileprivate func publishRevisionAfterSpawn() {
        notifyRevisionChanged()
    }
}

private extension simd_float4x4 {
    func withTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = self
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }
}
