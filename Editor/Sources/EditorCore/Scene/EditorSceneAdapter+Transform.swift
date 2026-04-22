import Foundation
import RenderBackend
import SceneRuntime
import simd

extension EditorSceneAdapter {
    /// 当前激活摄像机的 RenderCamera 描述；没有可用摄像机时返回回退默认值。
    public func currentRenderCamera() -> RenderCamera {
        scene.extractedRenderScene?.scene.camera ?? RenderCamera.fallbackPerspective
    }

    /// 推进编辑器持有的 SceneRuntime 一帧，使其 RenderScene 提取与
    /// 空间索引刷新到位。Editor 的渲染输出会喂给引擎的 RenderThread。
    @discardableResult
    public func tickScene(deltaTime: Double = 0) -> Bool {
        _ = scene.tick(deltaTime: deltaTime)
        return true
    }

    /// 当前帧应送到引擎渲染线程的 RenderScene 快照。
    public func currentRenderScene() -> RenderScene {
        scene.renderScene
    }

    /// 选中实体的世界坐标。用于 gizmo 在视口中定位。
    /// 优先返回最近一次 render extract 时的实例 transform，与渲染输出严格一致；
    /// 没有渲染实例时回退到当前 worldTransform 的平移分量。
    public func entityWorldPosition(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        if let extracted = scene.extractedRenderScene,
           let idx = extracted.instanceEntities.firstIndex(of: entity)
        {
            let m = extracted.scene.instances[idx].transform
            return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        guard let world = scene.worldTransform(for: entity) else { return nil }
        return world.translation
    }

    /// 选中实体当前的世界矩阵（与 `entityWorldPosition` 同源，优先使用渲染快照）。
    public func entityWorldMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        if let extracted = scene.extractedRenderScene,
           let idx = extracted.instanceEntities.firstIndex(of: entity)
        {
            return extracted.scene.instances[idx].transform
        }
        return scene.worldTransform(for: entity)?.matrix
    }

    /// 选中实体当前的 LocalTransform 平移分量。
    public func entityLocalTranslation(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        guard let local = scene.localTransform(for: entity) else { return nil }
        return local.translation
    }

    /// 直接覆盖实体的 LocalTransform 平移分量，保留旋转/缩放部分。
    /// 立即触发 `propagateTransforms` 与 revision 通知。
    public func setEntityLocalTranslation(_ rawID: UInt64, to value: SIMD3<Float>) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix.columns.3 = SIMD4<Float>(value.x, value.y, value.z, 1)
        _ = scene.setLocalTransform(local, for: entity)
        scene.propagateTransforms()
        notifyRevisionChanged()
    }

    /// 选中实体当前的完整 LocalTransform 矩阵。
    public func entityLocalMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.localTransform(for: entity)?.matrix
    }

    /// 选中实体父节点的世界矩阵；没有父节点时返回 identity。
    public func entityParentWorldMatrix(_ rawID: UInt64) -> simd_float4x4 {
        guard let entity = makeEntityID(rawID),
              let parent = scene.parent(of: entity),
              let parentWorld = scene.worldTransform(for: parent)
        else {
            return matrix_identity_float4x4
        }
        return parentWorld.matrix
    }

    /// 直接覆盖实体的 LocalTransform 矩阵（含旋转 / 缩放 / 平移）。
    public func setEntityLocalMatrix(_ rawID: UInt64, to matrix: simd_float4x4) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix = matrix
        _ = scene.setLocalTransform(local, for: entity)
        scene.propagateTransforms()
        notifyRevisionChanged()
    }

    private func makeEntityID(_ rawID: UInt64) -> EntityID? {
        EntityID(
            index: UInt32(rawID & 0xFFFF_FFFF),
            generation: UInt32(rawID >> 32)
        )
    }
}
