import AssetPipeline
@testable import EditorCore
import Foundation
import SceneRuntime
import Testing

@Suite("DCC geometry authoring", .serialized)
@MainActor
struct GeometryAuthoringTests {
    @Test("native geometry presets create assets, scene objects and inspector controls", arguments: EditorGeometryPreset.allCases)
    func presets(_ preset: EditorGeometryPreset) throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(preset))
            let asset = try #require(app.scene.referencedAsset(for: id))
            #expect(asset.kind == .dmesh)
            #expect(FileManager.default.fileExists(atPath: asset.absolutePath))
            #expect(app.store.selectedEntityID == id)
            let document = try #require(try app.geometryAuthoring.document(for: id))
            #expect(document.source == preset.document().source)
            let sections = app.scene.inspectorSections(for: id)
            #expect(sections.contains { $0.id == "geometry-source" })
            #expect(sections.contains { $0.id == "geometry-modifiers" })
            #expect(sections.contains { $0.id == "geometry-material-0" })
            app.undo()
            #expect(app.scene.entitySummary(id: id) == nil)
            app.redo()
            #expect(app.scene.entitySummary(id: id) != nil)
        }
    }

    @Test("geometry and transforms undo in chronological order, retaining derived collision geometry")
    func chronologicalHistory() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            let asset = try #require(app.scene.referencedAsset(for: id))
            #expect(app.geometryAuthoring.addModifier(.array(count: 2,offset: SIMD3(2,0,0)),to: id))
            app.scene.setEntityLocalTranslation(id,to: SIMD3(3,0,0))
            app.undo()
            #expect(app.scene.entityLocalTranslation(id) == .zero)
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers.count == 1)
            #expect(colliderMaxX(app,asset) == 2.5)
            app.undo()
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers.isEmpty == true)
            #expect(colliderMaxX(app,asset) == 0.5)
            app.redo()
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers.count == 1)
            #expect(colliderMaxX(app,asset) == 2.5)
            app.redo()
            #expect(app.scene.entityLocalTranslation(id) == SIMD3(3,0,0))
            #expect(colliderMaxX(app,asset) == 2.5)
        }
    }

    @Test("inspector edits persist source parameters, materials and modifier identities")
    func inspectorBindings() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            let source = try #require(app.scene.inspectorSections(for: id).first { $0.id == "geometry-source" })
            guard case let .vector3(x,_,_) = source.fields.first(where: { $0.id == "geometry-size" })?.value else {
                Issue.record("Missing source size control"); return
            }
            x.wrappedValue = 3
            #expect(try app.geometryAuthoring.document(for: id)?.source == .box(size: SIMD3(3,1,1)))
            #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            #expect(app.geometryAuthoring.addModifier(.array(count: 2,offset: SIMD3(4,0,0)),to: id))
            let doc = try #require(try app.geometryAuthoring.document(for: id))
            let firstID = doc.modifiers[0].id, secondID = doc.modifiers[1].id
            let section = try #require(app.geometryAuthoring.inspectorSections(for: id).first { $0.id == "geometry-modifier-\(secondID)" })
            guard case let .constrainedNumber(count,_,_,_,_) = section.fields.first(where: { $0.id == "\(secondID)-count" })?.value else {
                Issue.record("Missing array count control"); return
            }
            #expect(app.geometryAuthoring.moveModifier(secondID,by: -1,on: id))
            count.wrappedValue = 3
            let reordered = try #require(try app.geometryAuthoring.document(for: id))
            #expect(reordered.modifiers.map(\.id) == [secondID,firstID])
            #expect(reordered.modifiers[0].operation == .array(count: 3,offset: SIMD3(4,0,0)))
            #expect(app.geometryAuthoring.removeModifier(secondID,from: id))
            count.wrappedValue = 4 // An event from the removed row cannot mutate its successor.
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers[0].operation == .subdivision(levels: 1))
        }
    }

    @Test("apply through modifier preserves the evaluated mesh and is reversible")
    func applyModifier() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            #expect(app.geometryAuthoring.addModifier(.array(count: 2,offset: SIMD3(2,0,0)),to: id))
            let before = try #require(try app.geometryAuthoring.document(for: id))
            let vertices = try before.evaluate().mesh.vertices
            #expect(app.geometryAuthoring.applyModifier(before.modifiers[0].id,on: id))
            let after = try #require(try app.geometryAuthoring.document(for: id))
            #expect(after.modifiers.count == 1)
            if case let .polygon(mesh) = after.source { #expect(mesh.faces.count == 24) }
            else { Issue.record("Applying did not produce editable control topology") }
            #expect(try after.evaluate().mesh.vertices == vertices)
            app.undo()
            #expect(try app.geometryAuthoring.document(for: id) == before)
        }
    }

    @Test("invalid edits and conflicting history preserve the file and history entry")
    func rejectedEdits() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            let asset = try #require(app.scene.referencedAsset(for: id))
            let url = URL(fileURLWithPath: asset.absolutePath)
            let original = try Data(contentsOf: url)
            #expect(!app.geometryAuthoring.edit(entityID: id) { $0.source = .box(size: .zero) })
            #expect(try Data(contentsOf: url) == original)
            app.scene.setEntityLocked(true,entityIDs: [id])
            #expect(!app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            app.scene.setEntityLocked(false,entityIDs: [id])
            #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            let expected = try #require(try app.geometryAuthoring.document(for: id))
            var external = expected; external.name = "External change"
            try external.save(to: url)
            app.undo()
            #expect(try GeometryDocument.load(from: url) == external)
            #expect(app.canUndo && !app.canRedo)
            try expected.save(to: url)
            app.undo()
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers.isEmpty == true)
            #expect(app.canRedo)
        }
    }

    @Test("geometry history follows an asset rename and scene save/reopen")
    func renameAndReopen() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            let asset = try #require(app.scene.referencedAsset(for: id))
            #expect(app.relocateAsset(asset,to: "Assets/Geometry/Renamed.dmesh"))
            app.undo()
            #expect(try app.geometryAuthoring.document(for: id)?.modifiers.isEmpty == true)
            app.redo()
            #expect(app.scene.referencedAsset(for: id)?.meshIndex == asset.meshIndex)
            let saved = try #require(app.saveSceneManifest())
            app.scene.resetToPreviewScene()
            #expect(app.openSceneManifest(at: saved) != nil)
            let reopened = try #require(app.scene.roots.first?.id)
            #expect(try app.geometryAuthoring.document(for: reopened)?.modifiers.count == 1)
        }
    }

    @Test("unsaved text drafts and playback reject geometry writes")
    func draftsAndPlayback() throws {
        try withApp { app in
            let id = try #require(app.geometryAuthoring.create(.box))
            let asset = try #require(app.scene.referencedAsset(for: id))
            let original = try Data(contentsOf: URL(fileURLWithPath: asset.absolutePath))
            app.workstation.documents.open(asset.relativePath)
            app.workstation.documents.edit(asset.relativePath,text: String(decoding: original,as: UTF8.self) + "\n")
            #expect(app.workstation.documents.hasUnsavedChanges)
            #expect(!app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            #expect(try Data(contentsOf: URL(fileURLWithPath: asset.absolutePath)) == original)
            app.workstation.documents.reload(asset.relativePath,discard: true)
            app.store.dispatch(.setPlaybackState(.playing))
            #expect(!app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
            #expect(app.geometryAuthoring.create(.box) == nil)
            app.store.dispatch(.setPlaybackState(.stopped))
            #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
        }
    }

    private func colliderMaxX(_ app: EditorApplication, _ asset: EditorAsset) -> Float? {
        app.scene.scene.resource(MeshColliderBoundsResource.self)?.boundsByResourceID["meshIndex:\(asset.meshIndex)"]?.max.x
    }

    private func withApp(_ body: (EditorApplication) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dcc-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        try body(app)
    }
}
