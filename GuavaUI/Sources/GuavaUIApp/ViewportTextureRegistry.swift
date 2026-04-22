import GuavaUIRuntime
import RHIWGPU

/// Single-process bridge from an externally rendered `GPUTexture` to a
/// GuavaUI `TextureID`. Current Editor integration only has one live viewport,
/// so the bridge keeps one reusable slot and refreshes the bound texture when
/// the producer publishes a new surface pointer.
public final class ViewportTextureRegistry: ViewportTextureBridge, @unchecked Sendable {
    private let renderer: DrawListRenderer
    private let viewportTextureID: TextureID
    private var lastSurfaceID: UInt64 = 0
    private var lastWidth: UInt32 = 0
    private var lastHeight: UInt32 = 0

    public init(renderer: DrawListRenderer, viewportTextureID: TextureID = 10_000) {
        self.renderer = renderer
        self.viewportTextureID = viewportTextureID
    }

    public func textureID(surfaceID: UInt64, width: UInt32, height: UInt32) -> TextureID? {
        guard surfaceID != 0, width > 0, height > 0 else { return nil }

        if surfaceID != lastSurfaceID || width != lastWidth || height != lastHeight {
            guard let raw = UnsafeMutableRawPointer(bitPattern: UInt(surfaceID)) else {
                return nil
            }
            let texture = Unmanaged<GPUTexture>.fromOpaque(raw).takeUnretainedValue()
            do {
                try renderer.registerExternalColorTexture(
                    id: viewportTextureID,
                    texture: texture,
                    width: width,
                    height: height
                )
            } catch {
                return nil
            }
            lastSurfaceID = surfaceID
            lastWidth = width
            lastHeight = height
        }

        return viewportTextureID
    }
}