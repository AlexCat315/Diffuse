import ColorPipeline
import Testing

@Suite("ColorPipeline")
struct ColorPipelineTests {

    @Test("ACESConfig default is studio preset, ACEScg working space, sRGB display")
    func acesConfigDefaults() {
        let config = ACESConfig()
        #expect(config.configPreset == .studio)
        #expect(config.workingSpace == .acesCG)
        #expect(config.displayTransform == .sRGB)
        #expect(config.viewTransform == .unToneMapped)
    }

    @Test("ACESConfig pipelines a readable description")
    func acesConfigDescription() {
        let config = ACESConfig(
            preset: .studio,
            workingSpace: .acesCG,
            display: .sRGB,
            view: .unToneMapped
        )
        let desc = config.colorPipelineDescription
        #expect(desc.contains("studio"))
        #expect(desc.contains("ACEScg"))
        #expect(desc.contains("sRGB"))
        #expect(desc.contains("Un-tone-mapped"))
    }

    @Test("ACESConfig preset and color space enums are exhaustive")
    func acesConfigEnumExhaustiveness() {
        #expect(ACESConfigPreset.allCases.count == 3)
        #expect(ACESColorSpace.allCases.count == 4)
        #expect(ACESDisplayTransform.allCases.count == 5)
        #expect(ACESViewTransform.allCases.count == 4)
    }

    @Test("ViewTransform defaults to identity exposure and gamma")
    func viewTransformDefaults() {
        let vt = ViewTransform()
        #expect(vt.exposure == 0)
        #expect(vt.gamma == 1)
        #expect(vt.config.workingSpace == .acesCG)
    }

    @Test("ViewTransform fallback gamma corrects pixel values")
    func viewTransformFallbackGamma() {
        var pixels: [Float] = [0.5, 0.5, 0.5, 1,
                               0.25, 0.25, 0.25, 1]
        let vt = ViewTransform(gamma: 2.2)
        let applied = vt.apply(to: &pixels, width: 2, height: 1, using: nil)
        #expect(!applied) // OCIO not available, falls back to sRGB gamma
        #expect(pixels[0] > 0.5)  // gamma-encoded: 0.5^(1/2.2) ≈ 0.73
        #expect(pixels[4] > 0.25)
    }

    @Test("ViewTransform identity gamma leaves pixels unchanged")
    func viewTransformIdentityGamma() {
        var pixels: [Float] = [0.5, 0.3, 0.7, 1]
        let vt = ViewTransform(exposure: 0, gamma: 1)
        _ = vt.apply(to: &pixels, width: 1, height: 1, using: nil as OCIOBridge?)
        #expect(abs(pixels[0] - 0.5) < 0.001)
        #expect(abs(pixels[1] - 0.3) < 0.001)
        #expect(abs(pixels[2] - 0.7) < 0.001)
    }

    @Test("OCIOBridge description shows passthrough when unavailable")
    func ocioBridgeUnavailableDescription() {
        let config = ACESConfig()
        let vt = ViewTransform(config: config)
        let desc = vt.ocioDescription(bridge: nil)
        #expect(desc.contains("passthrough"))
        #expect(desc.contains("OCIO unavailable"))
    }
}
