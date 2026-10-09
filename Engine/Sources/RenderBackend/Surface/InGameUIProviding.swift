import Foundation
import NativeRHI
import RHIWGPU

/// A borrowed target in the scene renderer's active NativeRHI frame. The
/// provider records into these commands without beginning or submitting a frame.
public struct NativeInGameUITarget {
    public let device: Device
    public let commands: CommandBuffer
    public let color: RenderColorTarget
    public let format: TextureFormat
    public var sampleCount: Int = 1

    public init(device: Device, commands: CommandBuffer, color: RenderColorTarget, format: TextureFormat) {
        self.device = device; self.commands = commands; self.color = color; self.format = format
    }
}

public struct WGPUInGameUITarget {
    public let backend: WGPUBackend
    public let encoder: GPUCommandEncoder
    public let color: GPUTextureView
    public let format: GPUTextureFormat

    public init(backend: WGPUBackend, encoder: GPUCommandEncoder, color: GPUTextureView, format: GPUTextureFormat) {
        self.backend = backend; self.encoder = encoder; self.color = color; self.format = format
    }
}

public enum InGameUIRenderTarget {
    case native(NativeInGameUITarget)
    case wgpu(WGPUInGameUITarget)
}

/// Retains a recording's borrowed resources until submission. Acknowledge only
/// after the scene command buffer was submitted; abandoned records keep updates
/// pending. This token is used serially on the render thread.
public final class InGameUIRecording {
    public let drawCallCount: Int
    private var onSubmit: (() -> Void)?

    public init(drawCallCount: Int, onSubmit: @escaping () -> Void = {}) {
        self.drawCallCount = drawCallCount; self.onSubmit = onSubmit
    }
    public func didSubmit() {
        let action = onSubmit
        onSubmit = nil
        action?()
    }
}

/// Engine owns the GPU frame; GuavaUI supplies its most recent HUD geometry.
/// Called even when script canvas commands are empty: declarative HUDs can
/// still have content. Recording errors abort the entire scene submission.
public protocol InGameUIProviding: AnyObject, Sendable {
    func recordInGameUI(packet: RenderPacket, target: InGameUIRenderTarget) throws -> InGameUIRecording?
}

public final class InGameUIRegistry: @unchecked Sendable {
    public static let shared = InGameUIRegistry()
    private var installed: (any InGameUIProviding)?
    private let lock = NSLock()
    private init() {}

    public var provider: (any InGameUIProviding)? {
        get { lock.withLock { installed } }
        set { lock.withLock { installed = newValue } }
    }
}
