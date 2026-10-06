import Foundation
import SIMDCompat
import SceneRuntime
import Testing

@Suite("Grouped particle settings")
struct ParticleSettingsTests {
    @Test("Missing groups and fields use the defaults of their owners")
    func missingSettingsDefaults() throws {
        let data = Data(#"{"emission":{"emissionRate":12}}"#.utf8)
        let settings = try JSONDecoder().decode(ParticleEmitterSettings.self, from: data)
        var expected = ParticleEmitterSettings()
        expected.emission.emissionRate = 12
        #expect(settings == expected)
    }

    @Test("Configuration validates the owning groups before starting a simulation")
    func groupedValidation() {
        let emitter = ParticleEmitter(
            settings: .init {
                $0.emission.emissionRate = -10
                $0.shape.spawnRadius = -2
                $0.forces.noiseScale = 0
                $0.collision.collisionRestitution = 3
                $0.trails.ribbonSmoothingSegments = 100
                $0.gpuSimulation.workgroupSize = 0
            })
        #expect(emitter.settings.emission.emissionRate == 0)
        #expect(emitter.settings.shape.spawnRadius == 0)
        #expect(emitter.settings.forces.noiseScale == 0.0001)
        #expect(emitter.settings.collision.collisionRestitution == 1)
        #expect(emitter.settings.trails.ribbonSmoothingSegments == 16)
        #expect(emitter.settings.gpuSimulation.workgroupSize == 1)
        #expect(emitter.particles.isEmpty)
    }

    @Test("Scene records store grouped settings and preserve all seed bits and optional assets")
    func groupedSceneRoundTrip() throws {
        let emitter = ParticleEmitter(
            settings: .init {
                $0.emission.seed = .max
                $0.shape.originOffset = SIMD3<Float>(1, 2, 3)
                $0.textureSheet.textureAssetID = "Textures/fire.png"
                $0.textureSheet.texturePath = "/tmp/fire.png"
                $0.textureSheet.columns = 4
                $0.textureSheet.frameCount = 4
                $0.forces.gravity = SIMD3<Float>(0, -2, 0)
            })
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(emitter, for: entity)
        let data = try SceneSerializer.serialize(scene)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entities = try #require(object["entities"] as? [[String: Any]])
        let components = try #require(entities.first?["components"] as? [String: Any])
        let record = try #require(components["particleEmitter"] as? [String: Any])
        #expect(record["settings"] is [String: Any])
        #expect(record["emissionRate"] == nil)
        #expect(record["seed"] == nil)

        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        let result = try #require(restored.component(ParticleEmitter.self, for: restoredEntity))
        #expect(result.settings == emitter.settings)
    }

    @Test("Module application copies the whole group, including values not edited by the inspector")
    func wholeModuleApplication() throws {
        var emitter = ParticleEmitter()
        var stack = emitter.moduleStack
        let index = try #require(stack.modules.firstIndex { $0.id == "textureSheet" })
        let texture = ParticleTextureSheetModule {
            $0.textureAssetID = "smoke.png"
            $0.columns = 8
            $0.frameCount = 8
            $0.startFrame = 3
        }
        stack.modules[index].settings = .textureSheet(texture)
        emitter.apply(stack)
        #expect(emitter.settings.textureSheet == texture)
    }
}
