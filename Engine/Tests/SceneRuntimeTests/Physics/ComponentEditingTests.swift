import Foundation
import SceneRuntime
import Testing

@Suite("Physics component editing rules")
struct PhysicsComponentEditingTests {
    @Test("CCD toggles set motion quality while unrelated edits and explicit quality retain it")
    func ccdQuality() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(), for: entity)
        try scene.setComponentData(.object(["continuousCollisionDetection": .bool(true)]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        #expect(scene.component(RigidBody.self, for: entity)?.motionQuality == .linearCast)
        try scene.setComponentData(.object(["continuousCollisionDetection": .bool(false)]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        #expect(scene.component(RigidBody.self, for: entity)?.motionQuality == .discrete)
        try scene.setComponentData(.object(["motionQuality": .string("linearCast")]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        try scene.setComponentData(.object(["continuousCollisionDetection": .bool(false), "mass": .number(3)]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        #expect(scene.component(RigidBody.self, for: entity)?.motionQuality == .linearCast)
        try scene.setComponentData(.object(["continuousCollisionDetection": .bool(true)]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        try scene.setComponentData(.object(["continuousCollisionDetection": .bool(false), "motionQuality": .string("linearCast")]),
                                   typeID: "rigidbody", for: entity, mode: .merge)
        #expect(scene.component(RigidBody.self, for: entity)?.motionQuality == .linearCast)
    }

    @Test("cloth partial input normalizes fixed points, supports array patches and rejects wrong types atomically")
    func clothIndices() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 2), for: entity)
        try scene.setComponentData(.object(["fixedVertexIndices": .array([0, 5, 2, -1, 5, 999].map { .number(Double($0)) })]),
                                   typeID: "cloth", for: entity, mode: .merge)
        #expect(scene.component(Cloth.self, for: entity)?.fixedVertexIndices == [0, 2, 5])
        try scene.setComponentData(.object(["fixedVertexIndices": .object(["1": .number(1)])]),
                                   typeID: "cloth", for: entity, mode: .merge)
        #expect(scene.component(Cloth.self, for: entity)?.fixedVertexIndices == [0, 1, 5])
        try scene.setComponentData(.object(["gridSizeX": .number(2)]), typeID: "cloth", for: entity, mode: .merge)
        #expect(scene.component(Cloth.self, for: entity)?.fixedVertexIndices == [0, 1])
        let before = try SceneSerializer.serialize(scene)
        #expect(throws: ComponentEditError.invalidValue("cloth")) {
            try scene.setComponentData(.object(["spacing": .number(2), "fixedVertexIndices": .array([.bool(true)])]),
                                       typeID: "cloth", for: entity, mode: .merge)
        }
        #expect(try SceneSerializer.serialize(scene) == before)
        #expect(throws: ComponentEditError.invalidValue("cloth")) {
            try scene.setComponentData(.object(["fixedVertexIndices": .array([.number(1.5)])]),
                                       typeID: "cloth", for: entity, mode: .merge)
        }
        #expect(try SceneSerializer.serialize(scene) == before)
    }

    @Test("mesh partial input trims optional resources; normalization never applies to full replacement or hides unknown fields")
    func meshInput() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SoftBodyMesh(), for: entity)
        try scene.setComponentData(.object(["resourceID": .string("  mesh.tetra\n"),
            "fixedVertexIndices": .array([7, 2, -1, 2].map { .number(Double($0)) })]),
            typeID: "softBodyMesh", for: entity, mode: .merge)
        #expect(scene.component(SoftBodyMesh.self, for: entity)?.resourceID == "mesh.tetra")
        #expect(scene.component(SoftBodyMesh.self, for: entity)?.fixedVertexIndices == [2, 7])
        let before = try SceneSerializer.serialize(scene)
        #expect(throws: ComponentEditError.invalidValue("softBodyMesh")) {
            try scene.setComponentData(.object(["resourceID": .string(" changed "), "typo": .bool(true)]),
                                       typeID: "softBodyMesh", for: entity, mode: .merge)
        }
        #expect(throws: ComponentEditError.invalidValue("softBodyMesh")) {
            try scene.setComponentData(.object(["resourceID": .string(" changed ")]),
                                       typeID: "softBodyMesh", for: entity)
        }
        #expect(try SceneSerializer.serialize(scene) == before)
        try scene.setComponentData(.object(["resourceID": .string("  \n")]),
                                   typeID: "softBodyMesh", for: entity, mode: .merge)
        #expect(scene.component(SoftBodyMesh.self, for: entity)?.resourceID == nil)
        #expect(scene.componentData("softBodyMesh", for: entity)?.value(at: ["resourceID"]) == nil)
        let encoded = try SceneSerializer.serialize(scene)
        var restored = SceneRuntime()
        _ = try SceneSerializer.deserialize(encoded, into: &restored)
        #expect(try SceneSerializer.serialize(restored) == encoded)
    }
}
