import EngineMath
import Foundation
import simd

/// 进程级 mesh 包围盒注册表。RenderBackend 在 mesh 上传时填进来，
/// 编辑器（或任何只读消费者）可以按 meshIndex 查到 local-space AABB，
/// 用于拾取 / frustum culling / 调试可视化等。
///
/// 写操作受锁保护；读路径每次拿快照（COW dictionary），无锁。
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
