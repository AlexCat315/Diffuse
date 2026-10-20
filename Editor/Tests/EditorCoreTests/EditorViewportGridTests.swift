@testable import EditorCore
import Foundation
import Testing

@Suite("EditorViewportGrid")
@MainActor
struct EditorViewportGridTests {
    @Test("Studio backdrop belongs to editor presentation, while game preview keeps its sky")
    func presentationBackdrop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        #expect(app.makeViewportRenderSettings(shadowsEnabled: true, shadingMode: .lit).viewport.backdrop == .studio)
        app.store.dispatch(.setViewportMode(.game))
        let settings = app.makeViewportRenderSettings(shadowsEnabled: true, shadingMode: .lit)
        #expect(settings.viewport.backdrop == .sky)
        #expect(!settings.viewport.gridEnabled)
    }

    @Test("grid defaults on, toggles, and restores with editor state")
    func gridStatePersists() throws {
        var state = EditorState()
        #expect(state.viewport.gridEnabled)
        EditorReducer.reduce(state: &state, action: .setViewportGridEnabled(false))
        #expect(!state.viewport.gridEnabled)
        let data = try JSONEncoder().encode(state)
        #expect(try !JSONDecoder().decode(EditorState.self, from: data).viewport.gridEnabled)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var viewport = try #require(object["viewport"] as? [String: Any])
        viewport.removeValue(forKey: "gridEnabled")
        object["viewport"] = viewport
        let missingFieldData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(EditorState.self, from: missingFieldData).viewport.gridEnabled)
    }
}
