import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("Script language workspace", .serialized)
struct ScriptLanguageWorkspaceTests {
    @Test("creates an isolated SwiftPM target and shadow URI for every script")
    func createsIsolatedTargetsForScripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptsDirectory = root.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let modulePath = root.appendingPathComponent("EngineModules", isDirectory: true).path
        let moduleMapPath = root.appendingPathComponent("CEngineBridge.modulemap").path
        let includePath = root.appendingPathComponent("EngineIncludes", isDirectory: true).path

        let source = "import ScriptRuntime\nstruct GameScript: ScriptBehavior {}\n"
        let firstURL = scriptsDirectory.appendingPathComponent("Player.swift")
        let secondURL = scriptsDirectory.appendingPathComponent("Camera.swift")
        try source.write(to: firstURL, atomically: true, encoding: .utf8)
        try source.write(to: secondURL, atomically: true, encoding: .utf8)
        let scripts = [
            (DynamicScriptManager.ScriptFile(url: firstURL), source),
            (DynamicScriptManager.ScriptFile(url: secondURL), source),
        ]
        let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: scriptsDirectory,
                                                engineModulePaths: [modulePath],
                                                clangModuleMapPaths: [moduleMapPath],
                                                clangIncludePaths: [includePath])
        let documents = try workspace.synchronize(scripts)
        let first = try #require(documents[scripts[0].0.identifier])
        let second = try #require(documents[scripts[1].0.identifier])
        let manifest = try String(contentsOf: workspace.packageManifestURL, encoding: .utf8)

        #expect(first.targetName != second.targetName)
        #expect(first.analysisURL != second.analysisURL)
        #expect(first.sourceURL == firstURL)
        #expect(second.sourceURL == secondURL)
        #expect(try String(contentsOf: first.analysisURL, encoding: .utf8) == source)
        #expect(try String(contentsOf: second.analysisURL, encoding: .utf8) == source)
        #expect(manifest.contains(".unsafeFlags"))
        #expect(manifest.contains(modulePath))
        #expect(manifest.contains("-fmodule-map-file=\(moduleMapPath)"))
        #expect(manifest.contains("-I\(includePath)"))
        #expect(manifest.contains(first.targetName))
        #expect(manifest.contains(second.targetName))

        let dump = Pipe()
        let process = Process()
        process.executableURL = try SwiftScriptCompiler.resolveExecutableURL(for: "swift")
        process.arguments = ["package", "dump-package", "--package-path", workspace.rootURL.path]
        process.standardOutput = dump
        process.standardError = dump
        try process.run()
        let output = dump.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let dumped = String(decoding: output, as: UTF8.self)

        // `#expect`'s second parameter is `Comment`, not `String`, so a runtime
        // message has to be boxed explicitly.
        #expect(process.terminationStatus == 0, Comment(rawValue: dumped))
        #expect(dumped.contains(first.targetName))
        #expect(dumped.contains(second.targetName))
    }

    @Test("removes stale shadow targets without touching source scripts")
    func removesStaleTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptsDirectory = root.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let scriptURL = scriptsDirectory.appendingPathComponent("Player.swift")
        let source = "import ScriptRuntime\nstruct GameScript: ScriptBehavior {}\n"
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: scriptsDirectory,
                                                engineModulePaths: [],
                                                clangModuleMapPaths: [],
                                                clangIncludePaths: [])
        let script = DynamicScriptManager.ScriptFile(url: scriptURL)
        let documents = try workspace.synchronize([(script, source)])
        let document = try #require(documents[script.identifier])
        let staleURL = document.analysisURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Script_Stale")
        try FileManager.default.createDirectory(at: staleURL, withIntermediateDirectories: true)

        _ = try workspace.synchronize([])

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(!FileManager.default.fileExists(atPath: document.analysisURL.path))
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
    }
}
