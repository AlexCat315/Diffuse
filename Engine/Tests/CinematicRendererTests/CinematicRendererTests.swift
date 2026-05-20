import CinematicRenderer
import Foundation
import SIMDCompat
import Testing

@Suite("CinematicRenderer")
struct CinematicRendererTests {

    // MARK: - AOV Registry

    @Test("AOVRegistry includes built-in AOVs: beauty, diffuse, specular, depth, normal, cryptomatte")
    func aovRegistryBuiltins() {
        let registry = AOVRegistry()
        let ids = registry.allSpecs.map(\.id)
        #expect(ids.contains("beauty"))
        #expect(ids.contains("diffuse"))
        #expect(ids.contains("specular"))
        #expect(ids.contains("depth"))
        #expect(ids.contains("normal"))
        #expect(ids.contains("cryptomatte"))
        #expect(ids.contains("albedo"))
        #expect(ids.contains("emission"))
        #expect(ids.contains("ambient_occlusion"))
        #expect(ids.contains("motion_vector"))
    }

    @Test("AOVRegistry custom AOV registration")
    func aovRegistryCustomRegister() {
        let registry = AOVRegistry()
        registry.register(AOVSpec(id: "custom_heatmap", name: "Heatmap", channelCount: 1))
        let spec = registry.spec(id: "custom_heatmap")
        #expect(spec?.name == "Heatmap")
        #expect(spec?.channelCount == 1)
    }

    @Test("AOVRegistry total channel count sums all specs")
    func aovRegistryTotalChannels() {
        let registry = AOVRegistry()
        let total = registry.allSpecs.reduce(0) { $0 + $1.channelCount }
        #expect(registry.totalChannelCount == total)
        #expect(registry.totalChannelCount > 0)
    }

    // MARK: - Sampling Strategy

    @Test("Halton sampler produces values in [0, 1)")
    func haltonSamplerRange() {
        let sampler = HaltonSampler()
        for i in 0..<100 {
            let s = sampler.sample2D(i, sample: 0)
            #expect(s.x >= 0 && s.x < 1)
            #expect(s.y >= 0 && s.y < 1)
        }
    }

    @Test("Halton sampler is deterministic")
    func haltonSamplerDeterministic() {
        let sampler = HaltonSampler()
        let s0 = sampler.sample2D(0, sample: 0)
        let s1 = sampler.sample2D(0, sample: 0)
        #expect(s0 == s1)
    }

    @Test("SamplingStrategyPreset creates appropriate strategies")
    func samplingStrategyPresets() {
        for preset in SamplingStrategyPreset.allCases {
            let strategy = preset.create()
            let s = strategy.sample2D(42, sample: 7)
            #expect(s.x >= 0 && s.x <= 1)
            #expect(s.y >= 0 && s.y <= 1)
        }
    }

    // MARK: - Path Tracer

    @Test("PathTracerConfig default values match specification")
    func pathTracerConfigDefaults() {
        let config = PathTracerConfig()
        #expect(config.maxBounces == 4)
        #expect(config.samplesPerPixel == 64)
        #expect(config.russianRouletteDepth == 3)
        #expect(config.clampIndirect == 10)
    }

    @Test("PathTracer initial state has zero completed samples")
    func pathTracerInitialState() {
        let tracer = PathTracer(config: PathTracerConfig(samplesPerPixel: 64))
        #expect(tracer.state.completedSamples == 0)
        #expect(tracer.state.totalSamples == 64)
        #expect(!tracer.state.isComplete)
    }

    @Test("PathTracerState progress tracks completion")
    func pathTracerStateProgress() {
        var state = PathTracerState(totalSamples: 100)
        #expect(state.progress == 0)
        #expect(!state.isComplete)

        state.completedSamples = 50
        #expect(state.progress == 0.5)
        #expect(!state.isComplete)

        state.completedSamples = 100
        #expect(state.progress == 1.0)
        #expect(state.isComplete)
    }

    @Test("Ray construction normalizes direction")
    func rayNormalization() {
        let ray = Ray(origin: .zero, direction: SIMD3<Float>(0, 2, 0))
        #expect(abs(simd_length(ray.direction) - 1.0) < 0.001)
    }

    @Test("Ray point-at computes correct position on ray")
    func rayPointAt() {
        let ray = Ray(origin: SIMD3<Float>(1, 0, 0), direction: SIMD3<Float>(0, 0, 1))
        let p = ray.point(at: 5)
        #expect(p.x == 1)
        #expect(p.y == 0)
        #expect(p.z == 5)
    }
}
