import RenderBackend

/// Maps the viewport's presentation size (physical pixels of the on-screen
/// quad) to the engine's render resolution: presentation × renderScale ×
/// optional interaction downscale. Pure math, kept separate for tests.
public enum EditorViewportResolution {
    public static let maxDimension: UInt32 = 16_384
    /// Extra factor applied while a camera / gizmo drag is active and the
    /// interaction-downscale toggle is on.
    public static let interactionFactor: Float = 0.5

    public static func effectiveSize(presentation: RenderDrawableSize,
                                     renderScalePercent: Int,
                                     interactionDownscaleActive: Bool) -> RenderDrawableSize {
        var scale = Float(EditorState.sanitizedRenderScalePercent(renderScalePercent)) / 100
        if interactionDownscaleActive {
            scale *= interactionFactor
        }
        return RenderDrawableSize(
            width: scaled(presentation.width, by: scale),
            height: scaled(presentation.height, by: scale)
        )
    }

    private static func scaled(_ value: UInt32, by scale: Float) -> UInt32 {
        let raw = (Float(value) * scale).rounded()
        guard raw >= 1 else { return 1 }
        return min(UInt32(raw), maxDimension)
    }
}
