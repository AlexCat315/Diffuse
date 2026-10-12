import Foundation
import EditorCore

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

do {
    guard let project = argument("--project"), let output = argument("--output") else {
        throw NSError(domain: "GuavaProjectExport", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: GuavaProjectExport --project PATH --output PATH --static-scripts"])
    }
    let source = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL
    let data = try Data(contentsOf: source.appendingPathComponent(".guava/editor-scene-manifest.json"))
    let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
    let scene = EditorSceneAdapter(seedPreviewScene: false)
    if let error = scene.load(manifest: manifest).error { throw error }
    guard CommandLine.arguments.contains("--static-scripts") else {
        throw NSError(domain: "GuavaProjectExport", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Select --static-scripts for an Android export"])
    }
    let descriptor = try ProjectExporter.export(manifest: manifest,
        appName: argument("--name") ?? source.lastPathComponent,
        assets: EditorAssetCatalog.loadProject(at: source.path), sourceProjectDirectory: source,
        scriptBuildConfiguration: ProjectScriptBuildConfiguration(engineModulePaths: [], delivery: .staticLink),
        to: URL(fileURLWithPath: output, isDirectory: true))
    print("Exported \(descriptor.appName): \(descriptor.entityCount) entities, \(descriptor.assetCount) assets")
} catch {
    FileHandle.standardError.write(Data("Project export failed: \(error)\n".utf8))
    exit(1)
}
