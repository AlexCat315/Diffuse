import EngineKernel
import Foundation
import GameRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Crystal Rush actual gameplay", .serialized)
struct CrystalRushGameplayTests {
    #if os(macOS) || os(Linux)
    @Test("compiled example supports input, victory, damage, timeout and restart", .timeLimit(.minutes(2)))
    func playableLoop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["Editor/.build/out/Products/Debug/GuavaPlayer", "Editor/.build/debug/GuavaPlayer"]
        let playerBinary = try #require(candidates.map { root.appendingPathComponent($0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("guava-crystal-rules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let manager = DynamicScriptManager(projectDirectory: project.path, scriptRuntime: ScriptRuntime(), engineModulePaths: [])
        let source = try String(contentsOf: root.appendingPathComponent("examples/CrystalRush/Scripts/CrystalRush.swift"), encoding: .utf8)
        _ = try manager.createScript(name: "CrystalRush", source: source)
        let identifier = try #require(manager.scanScriptFiles().first).identifier
        let node = EditorSceneManifestNode(id: 0, name: "Game Controller", kind: "empty",
            components: [ManifestComponent(type: "script", value: ComponentValue(jsonObject: ["bindings": [encodeScriptBinding(ScriptBinding(identifier: identifier))]]))])
        let output = project.appendingPathComponent("export")
        _ = try ProjectExporter.export(manifest: EditorSceneManifest(revision: 0, entityCount: 1, roots: [node]),
            appName: "CrystalRules", sourceProjectDirectory: project, playerExecutableURL: playerBinary,
            scriptBuildConfiguration: ProjectScriptBuildConfiguration.discover(for: playerBinary), to: output)
        // Gameplay must work solely from compiled artifacts, without its source.
        try FileManager.default.removeItem(at: project.appendingPathComponent("Scripts"))
        let game = try GameApplication(projectDirectory: output.path)
        var frame: UInt64 = 0
        func tick(_ count: Int = 1, events: [InputEvent] = []) {
            for index in 0..<count {
                frame += 1
                game.scene.tickScene(deltaTime: 1.0 / 60, frameIndex: frame,
                                     inputEvents: index == 0 ? events : [], drivesAudio: false)
            }
        }
        func key(_ scan: UInt32, down: Bool) -> InputEvent {
            let event = KeyEvent(scancode: scan, keycode: scan, modifiers: [], isRepeat: false)
            return down ? .keyDown(event) : .keyUp(event)
        }
        func values() throws -> [String: String] {
            try #require(game.scene.scene.resource(ScriptDebugState.self)?.entities.values.first)
        }
        func position(_ point: SIMD3<Float>) throws {
            let entity = try #require(game.scene.scene.findEntity(named: "Player"))
            var transform = try #require(game.scene.scene.localTransform(for: entity))
            transform.translation = point
            _ = game.scene.scene.setLocalTransform(transform, for: entity)
        }
        tick(120)
        #expect(try values()["phase"] == "ready")
        #expect(try values()["remaining_seconds"] == "50.00")
        #expect(game.scene.manifest().entityCount == 60)
        #expect(!game.scene.currentInGameCanvas().commands.isEmpty)
        tick(events: [key(Scancode.space, down: true)])
        tick(events: [key(Scancode.space, down: false), key(Scancode.d, down: true)])
        tick(10)
        #expect(try #require(Float(values()["player_x"] ?? "")) > 0)
        tick(events: [key(Scancode.d, down: false)])
        for name in (1...8).map({ "Crystal \($0)" }) {
            let gem = try #require(game.scene.scene.findEntity(named: name))
            try position(try #require(game.scene.scene.localTransform(for: gem)).translation)
            tick()
            #expect(game.scene.scene.component(RenderMeshComponent.self, for: gem)?.isVisible == false)
        }
        #expect(try values()["score"] == "8")
        #expect(try values()["phase"] == "won")
        tick(events: [key(Scancode.r, down: true)])
        tick(events: [key(Scancode.r, down: false)])
        #expect(try values()["score"] == "0")
        #expect(try values()["hearts"] == "3")
        #expect(try values()["phase"] == "playing")
        for expectedHearts in [2, 1, 0] {
            let enemy = try #require(game.scene.scene.findEntity(named: "Sentinel 1"))
            try position(try #require(game.scene.scene.localTransform(for: enemy)).translation)
            tick()
            #expect(try values()["hearts"] == "\(expectedHearts)")
            if expectedHearts > 0 { try position(SIMD3(8, 0.6, 6)); tick(86) }
        }
        #expect(try values()["phase"] == "lost")
        tick(events: [key(Scancode.r, down: true)])
        tick(events: [key(Scancode.r, down: false)])
        try position(SIMD3(8, 0.6, 6))
        tick(120, events: [key(Scancode.d, down: true)])
        #expect(try values()["player_x"] == "8.25")
        tick(events: [key(Scancode.d, down: false)])
        tick(3100)
        #expect(try values()["phase"] == "lost")
        #expect(try values()["remaining_seconds"] == "0.00")
    }
    #endif
}
