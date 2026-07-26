@testable import EditorCore
import Foundation
import SceneRuntime
import Testing

@Suite("ProjectExporter", .serialized)
struct ProjectExporterTests {

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guava-export-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("export writes a descriptor, asset list, and player-loadable scene")
    func exportWritesBundle() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        defer { try? FileManager.default.removeItem(at: output) }

        let descriptor = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)
        #expect(descriptor.appName == "Demo")
        #expect(descriptor.entityCount == manifest.entityCount)
        #expect(descriptor.schemaVersion == ProjectExporter.schemaVersion)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: output.appendingPathComponent("build.json").path))
        #expect(fm.fileExists(atPath: output.appendingPathComponent("assets.json").path))
        // Scene is written where the player's project loader reads it.
        let sceneURL = GameSaveDocument.url(slot: ProjectExporter.sceneSlot, projectDirectory: output.path)
        #expect(fm.fileExists(atPath: sceneURL.path))

        // The descriptor reads back identically.
        #expect(try ProjectExporter.readDescriptor(from: output) == descriptor)
    }

    @Test("exported scene round-trips: a fresh adapter loads the same entity count")
    func exportedSceneIsLoadable() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)

        // Load exactly the way GameApplication does: GameSaveDocument at slot 0.
        let sceneURL = GameSaveDocument.url(slot: ProjectExporter.sceneSlot, projectDirectory: output.path)
        let doc = try #require(try GameSaveDocument.read(from: sceneURL))
        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: doc.manifest)
        #expect(result.entityCount == manifest.entityCount)
    }

    @Test("asset list captures referenced assets")
    func exportRecordsAssets() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        let project = tempDir()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: project)
        }
        let modelURL = project.appendingPathComponent("models/barrel.glb")
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: modelURL)

        let assets = [
            EditorAsset(id: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                        absolutePath: modelURL.path, kind: .glb, meshIndex: 3),
        ]
        let descriptor = try ProjectExporter.export(manifest: manifest, appName: "Demo",
                                                    assets: assets, to: output)
        #expect(descriptor.assetCount == 1)

        let data = try Data(contentsOf: output.appendingPathComponent("assets.json"))
        let list = try JSONDecoder().decode(ProjectExportAssetList.self, from: data)
        #expect(list.assets.count == 1)
        #expect(list.assets.first?.id == "a1")
        #expect(list.assets.first?.relativePath == "models/barrel.glb")
    }

    @Test("export copies model dependencies, audio resources, and project scripts")
    func exportCopiesRuntimeResources() throws {
        let project = tempDir()
        let output = project.appendingPathComponent("export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let modelDirectory = project.appendingPathComponent("Assets/Models", isDirectory: true)
        let audioDirectory = project.appendingPathComponent("Assets/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let modelURL = modelDirectory.appendingPathComponent("ship.gltf")
        try Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"ship.bin","byteLength":4}],"images":[{"uri":"textures/albedo.png"}]}"#.utf8)
            .write(to: modelURL)
        try Data([0, 1, 2, 3]).write(to: modelDirectory.appendingPathComponent("ship.bin"))
        try FileManager.default.createDirectory(at: modelDirectory.appendingPathComponent("textures"),
                                                withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: modelDirectory.appendingPathComponent("textures/albedo.png")
        )
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioDirectory.appendingPathComponent("theme.wav"))
        let scriptsURL = project.appendingPathComponent(ProjectScriptCatalog.relativePath)
        try FileManager.default.createDirectory(at: scriptsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"scripts":[]}"#.utf8).write(to: scriptsURL)
        let asset = EditorAsset(id: "Assets/Models/ship.gltf",
                                name: "ship",
                                relativePath: "Assets/Models/ship.gltf",
                                absolutePath: modelURL.path,
                                kind: .gltf,
                                meshIndex: 9)

        _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                       appName: "Demo",
                                       assets: [asset],
                                       sourceProjectDirectory: project,
                                       to: output)

        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/ship.gltf").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/ship.bin").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/textures/albedo.png").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Audio/theme.wav").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent(ProjectScriptCatalog.relativePath).path
        ))
    }

    @Test("re-export replaces stale bundle contents")
    func exportReplacesStaleContents() throws {
        let project = tempDir()
        let output = project.appendingPathComponent("export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sourceURL = project.appendingPathComponent("old.glb")
        try Data([1, 2, 3]).write(to: sourceURL)
        let asset = EditorAsset(id: "old.glb", name: "old", relativePath: "old.glb",
                                absolutePath: sourceURL.path, kind: .glb, meshIndex: 2)
        let manifest = EditorSceneAdapter().manifest()

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo",
                                       assets: [asset], to: output)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("old.glb").path))

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("old.glb").path))
    }

    @Test("custom project-local output is excluded from runtime resource scanning")
    func exportDoesNotRecopyPreviousCustomOutput() throws {
        let project = tempDir()
        let output = project.appendingPathComponent("Builds/Demo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let audio = project.appendingPathComponent("Assets/Audio/theme.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audio)

        // Simulate a previous export. Without explicitly excluding the requested
        // output directory, its stale resource is copied into Builds/Demo again.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: output.appendingPathComponent("old.wav"))

        _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                       appName: "Demo",
                                       sourceProjectDirectory: project,
                                       to: output)

        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Audio/theme.wav").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Builds/Demo/old.wav").path
        ))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("old.wav").path))
    }

    @Test("export rejects replacing a directory that contains the source project")
    func exportRejectsOutputContainingSourceProject() throws {
        let container = tempDir()
        let project = container.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let marker = project.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        #expect(throws: ProjectExporterError.outputContainsSourceProject(container.path)) {
            _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                           appName: "Demo",
                                           sourceProjectDirectory: project,
                                           to: container)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("export rejects asset destinations that traverse outside the bundle")
    func exportRejectsEscapingAssetDestination() throws {
        let root = tempDir()
        let output = root.appendingPathComponent("Export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.glb")
        try Data([1, 2, 3]).write(to: source)
        let asset = EditorAsset(id: "asset",
                                name: "asset",
                                relativePath: "../escaped.glb",
                                absolutePath: source.path,
                                kind: .glb,
                                meshIndex: 2)

        #expect(throws: ProjectExporterError.unsafeRelativePath("../escaped.glb")) {
            _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                           appName: "Demo",
                                           assets: [asset],
                                           to: output)
        }
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
    }

    @Test("export normalizes portable asset paths and rejects duplicate mesh slots")
    func exportValidatesAssetList() throws {
        let root = tempDir()
        let output = root.appendingPathComponent("Export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.glb")
        let secondURL = root.appendingPathComponent("second.glb")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: secondURL)
        let first = EditorAsset(id: "first", name: "first",
                                relativePath: "Assets\\first.glb",
                                absolutePath: firstURL.path, kind: .glb, meshIndex: 3)

        _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                       appName: "Demo", assets: [first], to: output)
        let list = try JSONDecoder().decode(
            ProjectExportAssetList.self,
            from: Data(contentsOf: output.appendingPathComponent("assets.json"))
        )
        #expect(list.assets.first?.relativePath == "Assets/first.glb")
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/first.glb").path
        ))

        let second = EditorAsset(id: "second", name: "second",
                                 relativePath: "Assets/second.glb",
                                 absolutePath: secondURL.path, kind: .glb, meshIndex: 3)
        #expect(throws: ProjectExporterError.conflictingMeshIndex(3)) {
            _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                           appName: "Demo", assets: [first, second], to: output)
        }
    }

    @Test("export packages a self-contained macOS application when a player is available")
    func exportPackagesApplication() throws {
        let output = tempDir()
        let playerDirectory = tempDir()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: playerDirectory)
        }
        try FileManager.default.createDirectory(at: playerDirectory,
                                                withIntermediateDirectories: true)
        let player = playerDirectory.appendingPathComponent("GuavaPlayer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: player)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: player.path)
        let resourceBundle = playerDirectory.appendingPathComponent("GuavaUI_Test.bundle",
                                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBundle,
                                                withIntermediateDirectories: true)
        try Data("resource".utf8).write(to: resourceBundle.appendingPathComponent("marker.txt"))

        _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                       appName: "Demo/Game",
                                       playerExecutableURL: player,
                                       to: output)

        let app = ProjectExporter.applicationBundleURL(appName: "Demo/Game", in: output)
        let executable = ProjectExporter.applicationExecutableURL(appName: "Demo/Game", in: output)
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        #expect(FileManager.default.fileExists(
            atPath: app.appendingPathComponent("GuavaUI_Test.bundle/marker.txt").path
        ))
        let embeddedProject = app.appendingPathComponent("Contents/Resources/GuavaProject",
                                                         isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: embeddedProject.appendingPathComponent("build.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: GameSaveDocument.url(slot: ProjectExporter.sceneSlot,
                                         projectDirectory: embeddedProject.path).path
        ))
        let plistData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        #expect(plist["CFBundleExecutable"] as? String == "Demo_Game")
        #expect(plist["LSMinimumSystemVersion"] as? String == "13.0")
    }

    @Test("portable player layout copies executable, resources, and runtime libraries")
    func portablePlayerLayoutCopiesRuntime() throws {
        let project = tempDir()
        let playerBuild = tempDir()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: playerBuild)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playerBuild, withIntermediateDirectories: true)
        let player = playerBuild.appendingPathComponent("custom-player")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: player)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: player.path)
        let resources = playerBuild.appendingPathComponent("GameRuntime.resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("resource".utf8).write(to: resources.appendingPathComponent("marker.txt"))
        let libraries = playerBuild.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: libraries.appendingPathComponent("libswiftCore.so"))
        try Data("native".utf8).write(to: playerBuild.appendingPathComponent("runtime.dll"))

        try ProjectExporter.createPortablePlayerBundle(playerExecutableURL: player,
                                                       projectDirectory: project)

        let executable = ProjectExporter.portablePlayerExecutableURL(in: project)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        #expect(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Player/GameRuntime.resources/marker.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Player/Lib/libswiftCore.so").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Player/runtime.dll").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Player/custom-player").path
        ))
    }
}
