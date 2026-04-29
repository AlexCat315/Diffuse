import Foundation
import SceneRuntime

public struct RenderDrawableSize: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32

    public init(width: UInt32 = 1, height: UInt32 = 1) {
        self.width = width
        self.height = height
    }
}

public enum RenderSurfaceDescriptor: @unchecked Sendable {
    case metalLayer(UnsafeMutableRawPointer)
    case win32Window(hwnd: UnsafeMutableRawPointer, hinstance: UnsafeMutableRawPointer?)
    case xlibWindow(display: UnsafeMutableRawPointer, window: UInt64)
    case waylandSurface(display: UnsafeMutableRawPointer, surface: UnsafeMutableRawPointer)
}

public struct RenderPacket: Sendable {
    public var frameIndex: Int
    public var deltaTime: Double
    public var drawableSize: RenderDrawableSize
    public var scene: RenderScene
    public var sceneSnapshot: SceneRuntimeSnapshot
    public var renderSettings: RenderSettings
    public var simulationTimeSeconds: Double

    public init(
        frameIndex: Int,
        deltaTime: Double,
        drawableSize: RenderDrawableSize,
        scene: RenderScene,
        sceneSnapshot: SceneRuntimeSnapshot,
        renderSettings: RenderSettings,
        simulationTimeSeconds: Double
    ) {
        self.frameIndex = frameIndex
        self.deltaTime = deltaTime
        self.drawableSize = drawableSize
        self.scene = scene
        self.sceneSnapshot = sceneSnapshot
        self.renderSettings = renderSettings
        self.simulationTimeSeconds = simulationTimeSeconds
    }
}

public protocol RenderPacketConsumer: AnyObject, Sendable {
    func initialize()
    func render(packet: RenderPacket)
    func currentFrameStats() -> RenderFrameStats
    func currentViewportSurfaceState() -> ViewportSurfaceState
}
