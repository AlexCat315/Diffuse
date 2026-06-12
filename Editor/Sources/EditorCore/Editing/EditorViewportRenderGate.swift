import RenderBackend
import SceneRuntime

/// Decides whether the engine should render the viewport this tick.
///
/// The signature samples the values that feed `RenderPacket` — a closed set:
/// if none changed, re-rendering would produce an identical image, so the
/// tick skips the GPU entirely (the editor stays on the last published
/// texture). Camera and palettes are compared by value, scene content by the
/// `RuntimeWorld` mutation revision, so there is no "remember to mark dirty"
/// discipline. A false-dirty merely degrades to today's continuous
/// rendering; a missed invalidation is caught by the heartbeat and by the
/// realtime toggle escape hatch.
public struct EditorViewportRenderGate {
    public struct Signature: Equatable {
        public var sceneRevision: UInt64
        public var camera: RenderCamera
        public var drawableSize: RenderDrawableSize
        public var settingsGeneration: UInt64
        public var jointPalettes: JointPaletteMap

        public init(sceneRevision: UInt64,
                    camera: RenderCamera,
                    drawableSize: RenderDrawableSize,
                    settingsGeneration: UInt64,
                    jointPalettes: JointPaletteMap) {
            self.sceneRevision = sceneRevision
            self.camera = camera
            self.drawableSize = drawableSize
            self.settingsGeneration = settingsGeneration
            self.jointPalettes = jointPalettes
        }
    }

    /// Missed-invalidation safety net: render at least this often while the
    /// editor ticks, so a forgotten dirty path shows up as a 1 Hz refresh
    /// instead of a frozen viewport.
    public static let heartbeatInterval: Double = 1.0
    /// Frames rendered after the last change. Covers in-flight completion
    /// handlers and double buffering.
    public static let convergenceFrames = 2
    /// TAA needs several frames after the last change for its history to
    /// converge; stopping earlier would freeze a half-resolved image.
    public static let temporalConvergenceFrames = 8

    private var lastSignature: Signature?
    private var lastRenderTime: Double = -.infinity
    private var pendingFrames = 0

    public init() {}

    public mutating func shouldRender(signature: Signature,
                                      forceContinuous: Bool,
                                      hasViewportInput: Bool,
                                      temporalEffectsActive: Bool,
                                      now: Double) -> Bool {
        if signature != lastSignature || forceContinuous || hasViewportInput {
            pendingFrames = temporalEffectsActive
                ? Self.temporalConvergenceFrames
                : Self.convergenceFrames
        }
        let render = pendingFrames > 0 || now - lastRenderTime >= Self.heartbeatInterval
        if render {
            lastSignature = signature
            lastRenderTime = now
            if pendingFrames > 0 { pendingFrames -= 1 }
        }
        return render
    }
}
