@testable import EditorCore
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Generated physics forms", .serialized)
struct GeneratedPhysicsFormTests {
    private func section(_ adapter: EditorSceneAdapter, _ id: UInt64, _ typeID: String) throws -> EditorInspectorSection {
        try #require(adapter.inspectorSections(for: id).first { $0.componentTypeID == typeID })
    }

    private func field(_ section: EditorInspectorSection, _ id: String) throws -> EditorInspectorFieldValue {
        try #require(section.fields.first { $0.id == id }?.value)
    }

    @Test("rigid-body generated controls preserve state, coalesce and undo the CCD companion value")
    func rigidBodyForm() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        let original = RigidBody(linearVelocity: SIMD3(1, 2, 3), accumulatedForce: SIMD3(4, 5, 6), isSleeping: true)
        _ = adapter.scene.setComponent(original, for: entity)
        adapter.resetEditHistory()
        #expect(adapter.inspectorRenderers["rigidbody"] == nil)
        let form = try section(adapter, entity.rawValue, "rigidbody")
        guard case let .stringOptions(motion, options) = try field(form, "motion"),
              case let .vector3(x, _, _) = try field(form, "linear-velocity"),
              case let .constrainedNumber(mass, _, _, _, _) = try field(form, "mass"),
              case let .bool(ccd) = try field(form, "continuous-collision-detection"),
              case .readOnly = try field(form, "sleeping"),
              case .readOnly = try field(form, "accumulatedForce") else {
            Issue.record("Expected generated rigid-body controls"); return
        }
        #expect(options.map(\.value) == RigidBodyMotionType.allCases.map(\.rawValue))
        let revision = adapter.revision
        motion.wrappedValue = "unsupported"
        mass.wrappedValue = .infinity
        #expect(adapter.revision == revision)
        adapter.beginInteractiveEditHistoryGroup()
        motion.wrappedValue = "kinematic"
        mass.wrappedValue = -1
        x.wrappedValue = 8
        ccd.wrappedValue = true
        adapter.endInteractiveEditHistoryGroup()
        var expected = original
        expected.motionType = .kinematic
        expected.mass = 0
        expected.linearVelocity.x = 8
        expected.continuousCollisionDetection = true
        expected.motionQuality = .linearCast
        #expect(adapter.scene.component(RigidBody.self, for: entity) == expected)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(RigidBody.self, for: entity) == original)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.redoEdit())
        ccd.wrappedValue = false
        #expect(adapter.scene.component(RigidBody.self, for: entity)?.motionQuality == .discrete)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(RigidBody.self, for: entity)?.motionQuality == .linearCast)
    }

    @Test("bounded integer controls round and clamp; soft-body diagnostics remain outside persistence")
    func softBodyForm() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(SoftBody(), for: entity)
        adapter.scene.setResource(SoftBodyStateFrameResource(states: [entity: SoftBodyMeshState(
            entity: entity, positions: [.zero, SIMD3(1, 2, 3)], isSleeping: true)]))
        adapter.resetEditHistory()
        let form = try section(adapter, entity.rawValue, "softBody")
        guard case let .constrainedNumber(iterations, _, _, _, _) = try field(form, "soft-body-iterations"),
              case let .constrainedNumber(layer, _, _, _, _) = try field(form, "soft-body-layer"),
              case let .constrainedNumber(mask, _, _, _, _) = try field(form, "soft-body-layer-mask"),
              case let .readOnly(vertices) = try field(form, "soft-body-streamed-vertices") else {
            Issue.record("Expected generated soft-body controls"); return
        }
        #expect(vertices == "2")
        #expect(adapter.scene.componentData("softBody", for: entity)?.value(at: ["positions"]) == nil)
        iterations.wrappedValue = 11.6
        #expect(adapter.scene.component(SoftBody.self, for: entity)?.solverIterations == 12)
        iterations.wrappedValue = .greatestFiniteMagnitude
        layer.wrappedValue = 200
        mask.wrappedValue = 100_000
        #expect(adapter.scene.component(SoftBody.self, for: entity)?.solverIterations == 128)
        #expect(adapter.scene.component(SoftBody.self, for: entity)?.layerID == 15)
        #expect(adapter.scene.component(SoftBody.self, for: entity)?.layerMask == .max)
        let revision = adapter.revision
        iterations.wrappedValue = .nan
        layer.wrappedValue = -.infinity
        #expect(adapter.revision == revision)
        #expect(adapter.scene.softBodyStateFrame.states[entity]?.positions.count == 2)
        #expect(adapter.inspectorRenderers.remove(componentTypeID: "softBody") != nil)
        let fallback = try section(adapter, entity.rawValue, "softBody")
        #expect(fallback.fields.contains { $0.id == "soft-body-iterations" })
        #expect(!fallback.fields.contains { $0.id == "soft-body-streamed-vertices" })
    }

    @Test("cloth forms use numeric enum values, normalize JSON and undo topology pruning for every selection")
    func clothForms() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let a = adapter.scene.createEntity(), b = adapter.scene.createEntity()
        let original = Cloth(gridSizeX: 3, gridSizeZ: 2, fixedVertexIndices: [0, 5])
        _ = adapter.scene.setComponent(original, for: a)
        _ = adapter.scene.setComponent(original, for: b)
        adapter.resetEditHistory()
        let form = try #require(adapter.inspectorSections(for: [a.rawValue, b.rawValue]).first { $0.componentTypeID == "cloth" })
        guard case let .constrainedNumber(grid, _, _, _, _) = try field(form, "cloth-grid-x"),
              case let .stringOptions(bend, options) = try field(form, "cloth-bend-type"),
              case let .json(indices, _) = try field(form, "cloth-fixed-vertices") else {
            Issue.record("Expected generated cloth controls"); return
        }
        #expect(options.map(\.value) == ["none", "distance", "dihedral"])
        grid.wrappedValue = 2.2
        #expect(adapter.scene.component(Cloth.self, for: a)?.fixedVertexIndices == [0])
        #expect(adapter.scene.component(Cloth.self, for: b)?.gridSizeX == 2)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(Cloth.self, for: a) == original)
        #expect(adapter.scene.component(Cloth.self, for: b) == original)
        #expect(!adapter.canUndoEdit)
        bend.wrappedValue = "dihedral"
        #expect(adapter.scene.componentData("cloth", for: a)?.value(at: ["bendType"]) == .number(2))
        indices.wrappedValue = "[5,2,-1,5,999]"
        #expect(adapter.scene.component(Cloth.self, for: a)?.fixedVertexIndices == [2, 5])
        let revision = adapter.revision
        indices.wrappedValue = "[true]"
        #expect(adapter.revision == revision)
        #expect(adapter.scene.component(Cloth.self, for: b)?.fixedVertexIndices == [2, 5])
        guard case let .readOnly(vertices) = try field(try section(adapter, a.rawValue, "cloth"), "cloth-vertex-count") else {
            Issue.record("Expected cloth topology diagnostic"); return
        }
        #expect(vertices == "6")
    }
}
