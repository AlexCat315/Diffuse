import Foundation
import SceneRuntime
import Testing

@Suite("Registry field descriptions")
struct ComponentInspectionTests {
    @Test("physics descriptions retain bounded integers, numeric enum storage and read-only simulation fields")
    func physicsDescriptions() throws {
        let scene = SceneRuntime()
        let descriptions = scene.componentDescriptions()
        let body = try #require(descriptions.first { $0.typeID == "rigidbody" })
        #expect(body.fields.first { $0.path == ["motionType"] }?.choices ==
            RigidBodyMotionType.allCases.map { ComponentFieldChoice($0.rawValue) })
        for key in ["isSleeping", "accumulatedForce", "accumulatedTorque", "kinematicTarget"] {
            #expect(body.fields.first { $0.path == [key] }?.isReadOnly == true)
        }
        let soft = try #require(descriptions.first { $0.typeID == "softBody" })
        let iterations = try #require(soft.fields.first { $0.path == ["solverIterations"] })
        #expect(iterations.kind == .integer && iterations.numeric.minimum == 1 && iterations.numeric.maximum == 128)
        #expect(!soft.fields.contains { $0.path == ["positions"] || $0.id == "soft-body-streamed-vertices" })
        let cloth = try #require(descriptions.first { $0.typeID == "cloth" })
        let bend = try #require(cloth.fields.first { $0.path == ["bendType"] })
        #expect(bend.kind == .options)
        #expect(bend.choices.map(\.id) == ["none", "distance", "dihedral"])
        #expect(bend.choices.map(\.value) == [0, 1, 2].map { .number(Double($0)) })
        let mesh = try #require(descriptions.first { $0.typeID == "softBodyMesh" })
        #expect(mesh.fields.first { $0.path == ["resourceID"] }?.isNullable == true)
        #expect(try JSONDecoder().decode([ComponentDescription].self,
            from: JSONEncoder().encode(descriptions)) == descriptions)
    }

    @Test("descriptions use codec defaults and never mutate the inspected scene")
    func registryDescriptions() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        try scene.addComponent(typeID: "camera", for: entity)
        _ = scene.updateComponent(CameraComponent.self, for: entity) { $0.isActive = true }
        let before = try SceneSerializer.serialize(scene)
        let revision = scene.snapshot.revision
        let descriptions = scene.componentDescriptions()
        #expect(descriptions.map(\.typeID) == scene.componentRegistry.componentSchemas.map(\.typeID))
        #expect(!descriptions.contains { $0.typeID == "localTransform" })
        let camera = try #require(descriptions.first { $0.typeID == "camera" })
        #expect(camera.requires == ["localTransform"])
        #expect(camera.defaults?.value(at: ["isActive"]) == .bool(false))
        let fov = try #require(camera.fields.first { $0.path == ["fovYRadians"] })
        #expect(fov.kind == .number)
        #expect(fov.numeric.scale == 180 / .pi)
        #expect(fov.numeric.minimum == 1 && fov.numeric.maximum == 179)
        #expect(scene.snapshot.revision == revision)
        #expect(try SceneSerializer.serialize(scene) == before)
        #expect(scene.componentDescriptions(typeID: "camera") == [camera])
        #expect(scene.componentDescriptions(typeID: "unregistered").isEmpty)
        let constraint = try #require(descriptions.first { $0.typeID == "constraint" })
        #expect(constraint.defaults == nil && !constraint.isUserAddable)
        #expect(constraint.fields.contains { $0.path == ["entityA"] && $0.kind == .integer })
        #expect(try JSONDecoder().decode([ComponentDescription].self,
            from: JSONEncoder().encode(descriptions)) == descriptions)
    }

    @Test("non-default-constructible schemas infer authored fields from existing instances")
    func authoredSample() throws {
        var scene = SceneRuntime()
        scene.componentRegistry.register(ComponentSchema(InspectionSource.self,
            typeID: "test.source", displayName: "Source", category: .gameplay,
            encode: { world, entity, context in
                guard world.hasComponent(InspectionSource.self, for: entity) else { return nil }
                return context.purpose == .authored ? .object(["authored": .bool(true)])
                    : .object(["authored": .bool(true), "transient": .number(100)])
            }, decode: { _, entity, _, world in _ = world.setComponent(InspectionSource(), for: entity) },
            makeDefault: { _, _ in }))
        let entity = scene.createEntity()
        _ = scene.setComponent(InspectionSource(), for: entity)
        let description = try #require(scene.componentDescriptions(typeID: "test.source").first)
        #expect(description.defaults == nil)
        #expect(description.fields.map(\.id) == ["authored"])
        #expect(scene.componentData("test.source", for: entity)?.value(at: ["transient"]) == .number(100))
    }

    @Test("field inference follows nested codec documents and explicit groups override descendants")
    func inferenceAndOverrides() throws {
        let document: ComponentValue = .object([
            "settings": .object(["enabled": .bool(true), "gain": .number(1.5)]),
            "offset": .array([.number(1), .number(2), .number(3)]),
            "seed": .unsignedInteger(.max), "items": .array([]), "optional": .null,
        ])
        let inferred = ComponentInspection().resolvedFields(for: document)
        #expect(inferred.first { $0.path == ["settings", "enabled"] }?.kind == .boolean)
        #expect(inferred.first { $0.path == ["settings", "gain"] }?.kind == .number)
        #expect(inferred.first { $0.path == ["offset"] }?.kind == .vector3)
        #expect(inferred.first { $0.path == ["seed"] }?.kind == .integer)
        #expect(inferred.first { $0.path == ["optional"] }?.kind == .json)
        let inspection = ComponentInspection {
            $0.isReadOnly = true
            $0.fields = [ComponentFieldDescriptor(["settings"]) { $0.kind = .json }]
        }
        let fields = inspection.resolvedFields(for: document)
        #expect(fields.filter { $0.path.starts(with: ["settings"]) }.count == 1)
        #expect(fields.allSatisfy { $0.isReadOnly })
        #expect(fields.map(\.path).contains(["items"]))
        let patched = try document.merging(.fieldPatch(.number(9), at: ["offset", "1"]))
        #expect(patched.value(at: ["offset"]) == .array([.number(1), .number(9), .number(3)]))
        #expect(patched.value(at: ["offset", "-1"]) == nil)
        #expect(patched.value(at: ["offset", "3"]) == nil)
        #expect(patched.value(at: []) == patched)
    }

    @Test("rendering and playback descriptions share nullable strings, color ranges and advanced fields with the editor")
    func generatedFormMetadata() throws {
        let scene = SceneRuntime()
        let mesh = try #require(scene.componentDescriptions(typeID: "renderMesh").first)
        #expect(mesh.fields.filter { !$0.isAdvanced }.map(\.id) == ["mesh-visible", "mesh-color-tint"])
        #expect(mesh.fields.first { $0.path == ["meshIndex"] }?.isReadOnly == true)
        let material = try #require(scene.componentDescriptions(typeID: "renderMaterial").first)
        let baseColor = try #require(material.fields.first { $0.path == ["baseColorFactor"] })
        let emissive = try #require(material.fields.first { $0.path == ["emissiveFactor"] })
        #expect(baseColor.kind == .color && baseColor.color.maximum == 1)
        #expect(emissive.kind == .color && emissive.color.minimum == 0 && emissive.color.maximum == nil)
        let player = try #require(scene.componentDescriptions(typeID: "animationPlayer").first)
        #expect(player.defaults?.value(at: ["clipName"]) == nil)
        #expect(player.fields.first { $0.id == "anim-clip" }?.kind == .string)
        #expect(player.fields.first { $0.id == "anim-clip" }?.isNullable == true)
        #expect(player.fields.first { $0.path == ["time"] }?.isReadOnly == true)
        #expect(player.fields.first { $0.path == ["time"] }?.isAdvanced == true)
        let encoded = try JSONEncoder().encode([mesh, material, player])
        #expect(try JSONDecoder().decode([ComponentDescription].self, from: encoded) == [mesh, material, player])
        let inferred = ComponentInspection {
            $0.inferredFieldsAreAdvanced = true
            $0.fields = [ComponentFieldDescriptor(["visible"]) { $0.kind = .boolean }]
        }.resolvedFields(for: .object(["visible": .bool(true), "details": .object(["gain": .number(1)])]))
        #expect(inferred.first { $0.id == "visible" }?.isAdvanced == false)
        #expect(inferred.first { $0.id == "details.gain" }?.isAdvanced == true)
    }
}

private struct InspectionSource: RuntimeComponent {}
