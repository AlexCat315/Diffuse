@testable import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorInspectorSections", .serialized)
struct EditorInspectorSectionsTests {

    private func makeEntity(in adapter: EditorSceneAdapter) -> UInt64 {
        adapter.scene.createEntity().rawValue
    }

    private func field(_ adapter: EditorSceneAdapter, _ rawID: UInt64,
                       section: String, field: String) -> EditorInspectorFieldValue? {
        for s in adapter.inspectorSections(for: rawID) where s.id == section {
            for f in s.fields where f.id == field { return f.value }
        }
        return nil
    }

    private func hasSection(_ adapter: EditorSceneAdapter, _ rawID: UInt64, _ id: String) -> Bool {
        adapter.inspectorSections(for: rawID).contains { $0.id == id }
    }

    // MARK: - Camera

    @Test("camera section appears only when the entity has a camera")
    func cameraSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "camera"))
        _ = adapter.addComponent(.camera, to: id)
        #expect(hasSection(adapter, id, "camera"))
    }

    @Test("camera active binding writes back to the component")
    func cameraActiveBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .bool(binding) = field(adapter, id, section: "camera", field: "camera-active") else {
            Issue.record("expected camera-active bool field"); return
        }
        binding.wrappedValue = true
        #expect(adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.isActive == true)
    }

    @Test("camera FOV binding shows degrees and stores radians")
    func cameraFOVBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "camera", field: "camera-fov") else {
            Issue.record("expected camera-fov number field"); return
        }
        binding.wrappedValue = 90 // degrees
        let radians = adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.fovYRadians
        #expect(radians != nil)
        #expect(abs(radians! - .pi / 2) < 1e-4)
        // And the getter reflects it back in degrees.
        #expect(abs(binding.wrappedValue - 90) < 1e-3)
    }

    // MARK: - Audio Listener

    @Test("audio listener volume binding writes back")
    func audioListenerBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.audioListener, to: id)
        #expect(hasSection(adapter, id, "audio-listener"))

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "audio-listener", field: "audio-listener-volume") else {
            Issue.record("expected master volume field"); return
        }
        binding.wrappedValue = 0.25
        #expect(adapter.scene.component(AudioListener.self, for: EntityID(rawValue: id)!)?.masterVolume == 0.25)
    }

    // MARK: - Particle Emitter

    @Test("particle emitter section appears with the component")
    func particleSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "particle-emitter"))
        _ = adapter.addComponent(.particleEmitter, to: id)
        #expect(hasSection(adapter, id, "particle-emitter"))
    }

    @Test("particle scalar and bool bindings write back")
    func particleScalarBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        if case let .constrainedNumber(rate, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rate") {
            rate.wrappedValue = 42
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionRate == 42)
        } else { Issue.record("missing rate field") }

        if case let .constrainedNumber(maxP, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max") {
            maxP.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxParticles == 128)
        } else { Issue.record("missing max field") }

        if case let .bool(emitting) = field(adapter, id, section: "particle-emitter", field: "particle-emitting") {
            emitting.wrappedValue = false
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.isEmitting == false)
        } else { Issue.record("missing emitting field") }
    }

    @Test("particle gravity vector and color bindings write back")
    func particleVectorAndColorBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        guard case let .vector3(gx, gy, gz) =
                field(adapter, id, section: "particle-emitter", field: "particle-gravity") else {
            Issue.record("expected gravity vector3"); return
        }
        gx.wrappedValue = 1; gy.wrappedValue = -20; gz.wrappedValue = 3
        let g = adapter.scene.component(ParticleEmitter.self, for: entity)?.gravity
        #expect(g == SIMD3<Float>(1, -20, 3))

        guard case let .color(start) =
                field(adapter, id, section: "particle-emitter", field: "particle-start-color") else {
            Issue.record("expected start color"); return
        }
        start.wrappedValue = Color(r: 1, g: 0, b: 0, a: 1)
        let c = adapter.scene.component(ParticleEmitter.self, for: entity)?.startColor
        #expect(c == SIMD4<Float>(1, 0, 0, 1))
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
