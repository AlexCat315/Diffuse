import Foundation
import IntentRuntime
import RenderBackend
import SceneRuntime
import SIMDCompat

extension EditorSceneAdapter {
    /// 褰撳墠婵€娲绘憚鍍忔満鐨?RenderCamera 鎻忚堪锛涙病鏈夊彲鐢ㄦ憚鍍忔満鏃惰繑鍥炲洖閫€榛樿鍊笺€?
    public func currentRenderCamera() -> RenderCamera {
        scene.extractedRenderScene?.scene.camera ?? RenderCamera.fallbackPerspective
    }

    /// 鎺ㄨ繘缂栬緫鍣ㄦ寔鏈夌殑 SceneRuntime 涓€甯э紝浣垮叾 RenderScene 鎻愬彇涓?
    /// 绌洪棿绱㈠紩鍒锋柊鍒颁綅銆侲ditor 鐨勬覆鏌撹緭鍑轰細鍠傜粰寮曟搸鐨?RenderThread銆?
    @discardableResult
    public func tickScene(deltaTime: Double = 0) -> Bool {
        _ = scene.tick(deltaTime: deltaTime)
        return true
    }

    /// 褰撳墠甯у簲閫佸埌寮曟搸娓叉煋绾跨▼鐨?RenderScene 蹇収銆?
    public func currentRenderScene() -> RenderScene {
        scene.renderScene
    }

    /// 閫変腑瀹炰綋鐨勪笘鐣屽潗鏍囥€傜敤浜?gizmo 鍦ㄨ鍙ｄ腑瀹氫綅銆?
    /// 鐩存帴璇?SceneRuntime 鐨?live worldTransform 鈥斺€?涓庢瘡娆?setLocalTransform 鍚?
    /// 绔嬪埢 propagateTransforms 鐨勫啓璺緞淇濇寔鍚屽抚涓€鑷达紝閬垮厤鎷栨嫿鏃?gizmo 姣旈紶鏍囨櫄涓€甯с€?
    public func entityWorldPosition(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.translation
    }

    /// 閫変腑瀹炰綋褰撳墠鐨勪笘鐣岀煩闃碉紙涓?`entityWorldPosition` 鍚屾簮锛屼娇鐢?live worldTransform锛夈€?
    public func entityWorldMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.matrix
    }

    /// 閫変腑瀹炰綋褰撳墠鐨?LocalTransform 骞崇Щ鍒嗛噺銆?
    public func entityLocalTranslation(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        guard let local = scene.localTransform(for: entity) else { return nil }
        return local.translation
    }

    /// 鐩存帴瑕嗙洊瀹炰綋鐨?LocalTransform 骞崇Щ鍒嗛噺锛屼繚鐣欐棆杞?缂╂斁閮ㄥ垎銆?
    /// 绔嬪嵆瑙﹀彂 `propagateTransforms` 涓?revision 閫氱煡銆?
    public func setEntityLocalTranslation(_ rawID: UInt64, to value: SIMD3<Float>) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix.columns.3 = SIMD4<Float>(value.x, value.y, value.z, 1)
        _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                  summary: "Update entity translation",
                                  targetRawIDs: [rawID],
                                  mutations: [.setLocalTransform(entityID: rawID, transform: local)])
    }

    /// 閫変腑瀹炰綋褰撳墠鐨勫畬鏁?LocalTransform 鐭╅樀銆?
    public func entityLocalMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.localTransform(for: entity)?.matrix
    }

    /// 閫変腑瀹炰綋鐖惰妭鐐圭殑涓栫晫鐭╅樀锛涙病鏈夌埗鑺傜偣鏃惰繑鍥?identity銆?
    public func entityParentWorldMatrix(_ rawID: UInt64) -> simd_float4x4 {
        guard let entity = makeEntityID(rawID),
              let parent = scene.parent(of: entity),
              let parentWorld = scene.worldTransform(for: parent)
        else {
            return matrix_identity_float4x4
        }
        return parentWorld.matrix
    }

    /// Returns true when `rawID` has an ancestor included in `candidateRawIDs`.
    /// Multi-selection gizmo edits use this to avoid transforming a child twice
    /// when both parent and child are selected.
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

    /// 鐩存帴瑕嗙洊瀹炰綋鐨?LocalTransform 鐭╅樀锛堝惈鏃嬭浆 / 缂╂斁 / 骞崇Щ锛夈€?
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
