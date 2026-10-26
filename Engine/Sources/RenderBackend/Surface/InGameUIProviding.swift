import Foundation
import NativeRHI

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

/// Engine owns the GPU frame; CoveUI supplies its most recent HUD geometry.
/// Called even when script canvas commands are empty: declarative HUDs can
/// still have content. Recording errors abort the entire scene submission.
public protocol InGameUIProviding: AnyObject, Sendable {
    func recordInGameUI(packet: RenderPacket, target: NativeInGameUITarget) throws -> InGameUIRecording?
}
