import AssetPipeline
@testable import EditorCore
import Foundation
import Testing

@Suite("Loop cut workflow",.serialized)
@MainActor
struct MeshLoopCutTests {
    @Test("count and slide previews start from the original; commit selects new loops and adds one undo entry")
    func commit() throws { try withApp { app,id,url in
        let model = app.meshEditing, source = try #require(model.controlMesh()), bytes = try Data(contentsOf: url)
        #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
        let modifiers = try #require(try app.geometryAuthoring.document(for: id)?.modifiers)
        let modifiedBytes = try Data(contentsOf: url)
        #expect(model.beginLoopCut()); #expect(model.selection.count == 4)
        #expect(model.previewLoopCut(cuts: 3,slide: -0.5))
        #expect(model.previewLoopCut(cuts: 2,slide: 0.25))
        model.synchronize()
        #expect(model.selection.count == 8 && model.controlMesh()?.positions.count == 16)
        #expect(try Data(contentsOf: url) == modifiedBytes && modifiedBytes != bytes)
        #expect(!model.beginTransform() && !model.deleteSelection() && !model.applyModifiers())
        #expect(model.commitLoopCut())
        let final = try #require(model.controlMesh())
        #expect(final.faces.count == 14 && model.selection.count == 8 && !model.hasInteractiveEdit)
        #expect(try GeometryDocument.load(from: url).source.evaluate() == final)
        #expect(try app.geometryAuthoring.document(for: id)?.modifiers == modifiers)
        app.undo(); model.synchronize(); #expect(model.controlMesh() == source)
        app.redo(); model.synchronize(); #expect(model.controlMesh() == final)
    } }

    @Test("invalid candidates keep the valid GPU preview but cannot confirm or save")
    func invalid() throws { try withApp { app,_,url in
        let model = app.meshEditing, bytes = try Data(contentsOf: url)
        #expect(model.beginLoopCut()); let valid = model.controlMesh()
        #expect(!model.previewLoopCut(cuts: 0,slide: 0))
        #expect(!model.isLoopCutPreviewValid && model.controlMesh() == valid)
        #expect(!model.commitLoopCut() && app.saveSceneManifest() == nil)
        #expect(!model.previewLoopCut(cuts: 2,slide: 1))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(model.previewLoopCut(cuts: 2,slide: -0.4)); #expect(model.cancelLoopCut())
        #expect(model.selection.count == 1 && model.controlMesh()?.faces.count == 6)
    } }

    @Test("undo and mode changes cancel the preview and restore the seed edge")
    func cancel() throws { try withApp { app,_,url in
        let model = app.meshEditing, seed = model.selection, bytes = try Data(contentsOf: url)
        #expect(model.beginLoopCut()); app.undo()
        #expect(model.selection == seed && !model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(model.beginLoopCut()); #expect(model.setMode(.face))
        #expect(!model.hasInteractiveEdit && model.controlMesh()?.faces.count == 6)
        #expect(try Data(contentsOf: url) == bytes)
    } }

    @Test("save commits the active tool and reopening retains its authored topology")
    func save() throws { try withApp { app,id,url in
        #expect(app.meshEditing.beginLoopCut()); #expect(app.meshEditing.previewLoopCut(cuts: 3,slide: 0.2))
        _ = try #require(app.saveSceneManifest())
        let source = try GeometryDocument.load(from: url)
        #expect(!app.meshEditing.hasInteractiveEdit && app.meshEditing.selection.count == 12)
        let restored = try EditorApplication(projectDirectory: app.projectDirectory,seedPreviewScene: false)
        defer { restored.shutdown() }
        _ = try #require(restored.openSceneManifest())
        #expect(try restored.geometryAuthoring.document(for: id) == source)
    } }

    @Test("external changes survive confirmation; unsupported topology cannot create an empty transaction")
    func conflicts() throws { try withApp { app,id,url in
        let model = app.meshEditing, seed = model.selection
        #expect(model.beginLoopCut())
        var external = try GeometryDocument.load(from: url); external.name = "External"
        try external.save(to: url)
        #expect(!model.commitLoopCut())
        #expect(model.selection == seed && !model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(try GeometryDocument.load(from: url) == external)
        #expect(app.geometryAuthoring.edit(entityID: id) { document in
            var mesh = try document.source.evaluate(); try mesh.triangulateFaces(Set(mesh.faces.indices)); document.source = .polygon(mesh: mesh)
        })
        model.synchronize(); model.select([0])
        let bytes = try Data(contentsOf: url)
        #expect(!model.beginLoopCut())
        #expect(!model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(try Data(contentsOf: url) == bytes)
    } }

    private func withApp(_ body: (EditorApplication,UInt64,URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loop-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        #expect(app.meshEditing.setMode(.edge))
        let seed = try #require(app.meshEditing.picker()?.edges.firstIndex(of: .init(0,1)))
        app.meshEditing.select([seed])
        try body(app,id,URL(fileURLWithPath: try #require(app.scene.referencedAsset(for: id)?.absolutePath)))
    }
}
