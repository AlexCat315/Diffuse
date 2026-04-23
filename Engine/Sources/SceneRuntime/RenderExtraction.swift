import simd

public struct RenderMeshComponent: RuntimeComponent, Sendable, Equatable {
    public var meshIndex: Int
    public var isVisible: Bool

    public init(meshIndex: Int, isVisible: Bool = true) {
        self.meshIndex = meshIndex
        self.isVisible = isVisible
    }
}

public struct CameraComponent: RuntimeComponent, Sendable, Equatable {
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fovYRadians: Float
    public var near: Float
    public var far: Float
    public var isActive: Bool

    public init(target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                fovYRadians: Float = .pi / 4,
                near: Float = 0.1,
                far: Float = 100.0,
                isActive: Bool = true) {
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.near = near
        self.far = far
        self.isActive = isActive
    }
}

public struct LightComponent: RuntimeComponent, Sendable, Equatable {
    public var color: SIMD3<Float>
    public var intensity: Float

    public init(color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                intensity: Float = 1.0) {
        self.color = color
        self.intensity = intensity
    }
}

public struct ExtractedRenderSceneResource: Sendable {
    public var scene: RenderScene
    public var activeCameraEntity: EntityID?
    public var instanceEntities: [EntityID]
    public var sourceRevision: UInt64

    public init(scene: RenderScene = .empty,
                activeCameraEntity: EntityID? = nil,
                instanceEntities: [EntityID] = [],
                sourceRevision: UInt64 = 0) {
        self.scene = scene
        self.activeCameraEntity = activeCameraEntity
        self.instanceEntities = instanceEntities
        self.sourceRevision = sourceRevision
    }
}

public extension RenderCamera {
    static let fallbackPerspective = RenderCamera(
        eye: SIMD3<Float>(0, 2.4, 7.5),
        target: .zero
    )
}

public extension RenderScene {
    static let empty = RenderScene(camera: .fallbackPerspective)
}