import AssetPipeline
@testable import EditorCore
import Foundation
import Testing

@Suite("Mesh inset workflow",.serialized)
@MainActor
struct MeshInsetTests {
    @Test("previews start from the source, preserve cap selection and leave disk untouched until one commit")
    func commit() throws { try withApp { app,id,url in
        let model = app.meshEditing, source = try #require(model.controlMesh()), bytes = try Data(contentsOf: url)
        #expect(model.beginInset())
        #expect(model.previewInset(distance: 0.2))
        #expect(model.previewInset(distance: 0.1))
        model.synchronize()
        #expect(model.selection == [1] && model.controlMesh()?.positions.count == 12)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!model.triangulateSelection() && !model.extrudeRegion() && !model.beginTransform())
        model.selectAll(); model.invertSelection(); #expect(model.selection == [1])
        #expect(model.commitInset())
        let inset = try #require(model.controlMesh())
        #expect(inset.faces.count == 10 && model.selection == [1])
        #expect(try GeometryDocument.load(from: url).source.evaluate() == inset)
        app.undo(); model.synchronize(); #expect(model.controlMesh() == source)
        app.redo(); model.synchronize(); #expect(model.controlMesh() == inset)
        model.select([1]); model.extrusionDistance = -0.2
        #expect(model.extrudeRegion())
        #expect(model.controlMesh()?.faces.count == 14)
    } }

    @Test("invalid widths retain the last valid preview but cannot confirm or save it")
    func invalid() throws { try withApp { app,_,url in
        let model = app.meshEditing, bytes = try Data(contentsOf: url)
        #expect(model.beginInset()); #expect(model.previewInset(distance: 0.2))
        let valid = model.controlMesh()
        #expect(!model.previewInset(distance: 2))
        #expect(!model.isInsetPreviewValid && model.insetDistance == 2 && model.controlMesh() == valid)
        #expect(!model.commitInset() && app.saveSceneManifest() == nil)
        #expect(model.isInsetting && app.geometryAuthoring.hasInteractiveEdit)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(model.previewInset(distance: 0.15)); #expect(model.isInsetPreviewValid)
        #expect(model.cancelInset()); #expect(model.controlMesh()?.faces.count == 6)
    } }

    @Test("undo, mode changes and leaving edit mode cancel a preview without adding history")
    func cancel() throws { try withApp { app,_,url in
        let model = app.meshEditing, bytes = try Data(contentsOf: url)
        #expect(model.beginInset()); app.undo()
        #expect(!model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(model.selection == [1] && model.controlMesh()?.faces.count == 6)
        #expect(model.beginInset()); #expect(model.setMode(.edge))
        #expect(!model.hasInteractiveEdit && model.controlMesh()?.faces.count == 6)
        #expect(model.setMode(.face)); model.select([1]); #expect(model.beginInset())
        model.leave()
        #expect(!model.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(try Data(contentsOf: url) == bytes)
        app.undo() // Source conversion, with no committed inset between it and undo.
        #expect(try GeometryDocument.load(from: url).source == .box(size: .init(repeating: 1)))
    } }

    @Test("saving commits the preview and preserves it across scene reopening")
    func save() throws { try withApp { app,id,url in
        #expect(app.meshEditing.beginInset()); #expect(app.meshEditing.previewInset(distance: 0.15))
        _ = try #require(app.saveSceneManifest())
        #expect(!app.meshEditing.hasInteractiveEdit)
        let source = try GeometryDocument.load(from: url)
        #expect(try source.source.evaluate().faces.count == 10)
        let restored = try EditorApplication(projectDirectory: app.projectDirectory,seedPreviewScene: false)
        defer { restored.shutdown() }
        _ = try #require(restored.openSceneManifest())
        #expect(try restored.geometryAuthoring.document(for: id) == source)
    } }

    @Test("external changes cannot be overwritten by confirming an old preview")
    func conflict() throws { try withApp { app,_,url in
        #expect(app.meshEditing.beginInset())
        var external = try GeometryDocument.load(from: url); external.name = "External"
        try external.save(to: url)
        #expect(!app.meshEditing.commitInset())
        #expect(!app.meshEditing.hasInteractiveEdit && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(try GeometryDocument.load(from: url) == external)
    } }

    @Test("cancelling after external topology changes drops stale component selection")
    func externalCancel() throws { try withApp { app,id,url in
        let slot = try #require(app.scene.referencedAsset(for: id)?.meshIndex)
        #expect(app.meshEditing.beginInset())
        var external = try GeometryDocument.load(from: url)
        var mesh = try external.source.evaluate(); try mesh.delete(faces: Set(mesh.faces.indices))
        external.source = .polygon(mesh: mesh); try external.save(to: url)
        #expect(app.meshEditing.cancelInset())
        #expect(app.meshEditing.selection.isEmpty && app.meshEditing.controlMesh() == mesh)
        #expect(AssetRegistry.shared.meshAsset(for: slot)?.triangleCount == 0)
        #expect(!app.geometryAuthoring.hasInteractiveEdit)
    } }

    private func withApp(_ body: (EditorApplication,UInt64,URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-inset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.select([1])
        let url = URL(fileURLWithPath: try #require(app.scene.referencedAsset(for: id)?.absolutePath))
        try body(app,id,url)
    }
}
