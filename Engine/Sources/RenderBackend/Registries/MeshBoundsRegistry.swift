import EngineMath
import Foundation
import SIMDCompat

/// 杩涚▼绾?mesh 鍖呭洿鐩掓敞鍐岃〃銆俁enderBackend 鍦?mesh 涓婁紶鏃跺～杩涙潵锛?
/// 缂栬緫鍣紙鎴栦换浣曞彧璇绘秷璐硅€咃級鍙互鎸?meshIndex 鏌ュ埌 local-space AABB锛?
/// 鐢ㄤ簬鎷惧彇 / frustum culling / 璋冭瘯鍙鍖栫瓑銆?
///
/// 鍐欐搷浣滃彈閿佷繚鎶わ紱璇昏矾寰勬瘡娆℃嬁蹇収锛圕OW dictionary锛夛紝鏃犻攣銆?
public final class MeshBoundsRegistry: @unchecked Sendable {
    public static let shared = MeshBoundsRegistry()

    private let lock = NSLock()
    private var storage: [Int: Bounds3D] = [:]

    private init() {}

    public func register(meshIndex: Int,
                         min: SIMD3<Float>,
                         max: SIMD3<Float>) {
        register(meshIndex: meshIndex, bounds: Bounds3D(min: min, max: max))
    }

    public func register(meshIndex: Int, bounds: Bounds3D) {
        lock.lock()
        storage[meshIndex] = bounds
        lock.unlock()
    }

    public func bounds(for meshIndex: Int) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let bounds = bounds3D(for: meshIndex) else { return nil }
        return (bounds.min, bounds.max)
    }

    public func bounds3D(for meshIndex: Int) -> Bounds3D? {
        lock.lock()
        let value = storage[meshIndex]
        lock.unlock()
        return value
    }

    public func clearAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
