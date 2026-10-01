import Foundation
import GameRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Exported Swift gameplay", .serialized)
struct GameProjectScriptLoaderTests {
    private func temporaryProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guava-script-export-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeManifest(_ manifest: ProjectCompiledScripts, to project: URL) throws {
        let url = project.appendingPathComponent(ProjectCompiledScripts.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url)
    }

    @Test("projects without compiled scripts retain preset-only playback")
    func missingManifest() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(try GameProjectScriptLoader().load(projectDirectory: project, into: ScriptRuntime()).isEmpty)
    }

    @Test("incompatible script artifacts are rejected before loading")
    func incompatibleTarget() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try writeManifest(ProjectCompiledScripts(entries: [], target: "different-platform"), to: project)
        #expect(throws: GameProjectScriptLoadError.incompatibleTarget("different-platform")) {
            try GameProjectScriptLoader().load(projectDirectory: project, into: ScriptRuntime())
        }
    }

    @Test("library paths cannot traverse outside the export")
    func escapingLibraryPath() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let entry = ProjectCompiledScripts.Entry(identifier: "scripts.asset.test", displayName: "Test",
                                                 libraryPath: "../outside.dylib", sha256: "")
        try writeManifest(ProjectCompiledScripts(entries: [entry]), to: project)
        #expect(throws: GameProjectScriptLoadError.invalidLibraryPath(entry.libraryPath)) {
            try GameProjectScriptLoader().load(projectDirectory: project, into: ScriptRuntime())
        }
    }

    @Test("corrupted libraries never register partially loaded gameplay")
    func corruptedArtifact() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let path = "Scripts/Compiled/test.dylib"
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupted".utf8).write(to: url)
        let entry = ProjectCompiledScripts.Entry(identifier: "scripts.asset.test", displayName: "Test",
                                                 libraryPath: path, sha256: "not-the-digest")
        try writeManifest(ProjectCompiledScripts(entries: [entry]), to: project)
        let runtime = ScriptRuntime()
        #expect(throws: GameProjectScriptLoadError.corruptedLibrary(path)) {
            try GameProjectScriptLoader().load(projectDirectory: project, into: runtime)
        }
        #expect(runtime.registeredScriptIdentifiers.isEmpty)
    }

    #if os(macOS) || os(Linux)
    @Test("exported gameplay runs in Player without sources or a compiler", .timeLimit(.minutes(2)))
    func exportedGameplayRunsInPlayer() throws {
        let fileManager = FileManager.default
        let editorRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["GUAVA_TEST_PLAYER_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
        let candidates = [override,
                          editorRoot.appendingPathComponent(".build/out/Products/Debug/GuavaPlayer"),
                          editorRoot.appendingPathComponent(".build/debug/GuavaPlayer")].compactMap { $0 }
        let player = try #require(candidates.first { fileManager.isExecutableFile(atPath: $0.path) })
        let configuration = ProjectScriptBuildConfiguration.discover(for: player)
        #expect(!configuration.engineModulePaths.isEmpty)
        let project = try temporaryProject()
        defer { try? fileManager.removeItem(at: project) }
        let manager = DynamicScriptManager(projectDirectory: project.path, scriptRuntime: ScriptRuntime(),
                                           engineModulePaths: [])
        let source = try manager.createScript(name: "Player", source: """
        import SceneRuntime
        import ScriptRuntime
        import SIMDCompat
        struct GameScript: ScriptBehavior {
            private var updates: Float = 0
            mutating func onStart(_ context: ScriptContext) {
                context.createEntity(named: "Spawned")
            }
            mutating func onUpdate(_ context: ScriptContext) {
                updates += 1
                context.translate(by: SIMD3<Float>(updates * (context.floatParameter("speed") ?? 1), 0, 0))
            }
        }
        """)
        let script = try #require(manager.scanScriptFiles().first)
        let alias = try #require(script.legacyIdentifiers.first)
        let component = ScriptComponent(bindings: [ScriptBinding(identifier: script.identifier, parametersJSON: #"{"speed":2}"#),
                                                   ScriptBinding(identifier: alias, parametersJSON: #"{"speed":2}"#)])
        let node = EditorSceneManifestNode(id: 1, name: "Player", kind: "empty",
                                           script: EditorSceneManifestScript(component))
        let scene = EditorSceneManifest(revision: 0, entityCount: 1, roots: [node])
        let output = project.appendingPathComponent("export")
        _ = try ProjectExporter.export(manifest: scene, appName: "ScriptTest", sourceProjectDirectory: project,
                                       playerExecutableURL: player, scriptBuildConfiguration: configuration, to: output)
        let manifestURL = output.appendingPathComponent(ProjectCompiledScripts.relativePath)
        let originalManifest = try Data(contentsOf: manifestURL)
        let compiled = try JSONDecoder().decode(ProjectCompiledScripts.self, from: originalManifest)
        #expect(compiled.entries.map(\.identifier) == [script.identifier])

        // An older Player that does not support validation cannot replace a
        // working bundle, even if the script compiler itself succeeds.
        let legacyPlayer = project.appendingPathComponent("LegacyPlayer")
        try "#!/bin/sh\nprintf 'legacy player\\n'\n".write(to: legacyPlayer, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyPlayer.path)
        #expect(throws: ProjectExporterError.scriptPlayerValidationFailed("legacy player\n")) {
            try ProjectExporter.export(manifest: scene, appName: "ScriptTest", sourceProjectDirectory: project,
                                       playerExecutableURL: legacyPlayer, scriptBuildConfiguration: configuration, to: output)
        }
        #expect(try Data(contentsOf: manifestURL) == originalManifest)

        // A compiler error must preserve the last successful export as a whole.
        try "invalid swift source".write(to: source, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try ProjectExporter.export(manifest: scene, appName: "ScriptTest", sourceProjectDirectory: project,
                                       playerExecutableURL: player, scriptBuildConfiguration: configuration, to: output)
        }
        #expect(try Data(contentsOf: manifestURL) == originalManifest)
        try fileManager.removeItem(at: project.appendingPathComponent("Scripts"))

        let app = try GameApplication(projectDirectory: output.path)
        app.simulateFrames(2)
        #expect(app.compiledScriptCount == 1)
        #expect(app.scene.manifest().entityCount == 3)
        let entity = try #require(app.scene.scene.entities(with: ScriptComponent.self).first)
        #expect(app.scene.scene.localTransform(for: entity)?.translation.x == 12)

        #if os(macOS)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none",
                          ProjectExporter.applicationBundleURL(appName: "ScriptTest", in: output).path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)
        #endif
        let process = Process()
        process.executableURL = ProjectExporter.runnableExecutableURL(appName: "ScriptTest", in: output)
        process.arguments = ["--validate-project", "--simulation-frames", "2"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/guava-no-toolchain"
        environment.removeValue(forKey: "GUAVA_PROJECT_DIR")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let report = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: errors))
        #expect(report.contains("1 compiled scripts, 3 entities, 2 simulation frames"))
    }
    #endif
}
