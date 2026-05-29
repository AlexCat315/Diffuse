@testable import EditorCore
import GuavaUICompose
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
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
