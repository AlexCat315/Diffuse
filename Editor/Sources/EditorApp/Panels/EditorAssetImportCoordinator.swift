import AssetPipeline
import EditorCore
import Foundation
import GuavaUIApp
import GuavaUIRuntime

/// Shared asset-import workflow used by both the Content Browser and the
/// application File menu. Keeping the picker and copy path together prevents
/// one entry point from silently degrading into a mere asset rescan.
enum EditorAssetImportCoordinator {
    static func requestImport(app: EditorApplication, into folder: String = "") {
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Asset import is unavailable",
                           severity: .error,
                           detail: "No active display is available to present the file picker.")
            return
        }
        MainActor.assumeIsolated {
            display.requestOpenFile(
                filters: [(name: L("3D Models"),
                           extensions: AssetImportResolver.supportedModelExtensions.sorted()),
                          (name: L("Textures"),
                           extensions: AssetImportResolver.supportedTextureExtensions.sorted())],
                allowsMultiple: true,
                defaultPath: importDestination(app: app, folder: folder)
            ) { paths in
                importFiles(paths, app: app, into: folder)
            }
        }
    }

    static func importDestination(app: EditorApplication, folder: String) -> String {
        let base = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
        return folder.isEmpty ? base.path : base.appendingPathComponent(folder, isDirectory: true).path
    }

    /// Imports each supported file plus its local dependencies and reports a
    /// useful summary to the editor console.
    static func importFiles(_ paths: [String], app: EditorApplication, into folder: String) {
        guard !paths.isEmpty else { return }
        let destDir = URL(fileURLWithPath: importDestination(app: app, folder: folder),
                          isDirectory: true).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            app.logConsole("Failed to prepare asset import directory",
                           severity: .error,
                           detail: String(describing: error))
            return
        }

        var importedNames: [String] = []
        var missingDependencies: [String] = []
        var failedImports: [String] = []
        var unsupported: [String] = []

        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard AssetImportResolver.isSupported(source) else {
                unsupported.append(source.lastPathComponent)
                continue
            }
            let outcome = copyAsset(from: source, into: destDir)
            if outcome.copied { importedNames.append(source.lastPathComponent) }
            missingDependencies.append(contentsOf: outcome.missing)
            failedImports.append(contentsOf: outcome.failures)
        }

        if !importedNames.isEmpty {
            _ = app.reloadAssets()
            AssetThumbnailRasterizer.invalidate()
            ImageAssetRegistryHolder.current?.clear()
            app.logConsole("Imported \(importedNames.count) asset\(importedNames.count == 1 ? "" : "s")",
                           detail: importedNames.joined(separator: ", "))
        }
        if !missingDependencies.isEmpty {
            app.logConsole("Asset imported with missing dependencies",
                           severity: .warning,
                           detail: missingDependencies.joined(separator: ", "))
        }
        if !failedImports.isEmpty {
            app.logConsole("Failed to import asset files",
                           severity: .error,
                           detail: failedImports.joined(separator: ", "))
        }
        if !unsupported.isEmpty {
            app.logConsole("Unsupported format — import models or textures",
                           severity: .warning,
                           detail: unsupported.joined(separator: ", "))
        }
    }

    static func copyAsset(from source: URL,
                          into destinationDirectory: URL) -> (copied: Bool,
                                                              missing: [String],
                                                              failures: [String]) {
        var copiedAny = false
        var missing: [String] = []
        var failures: [String] = []
        for file in AssetImportResolver.resolve(source) {
            let target = destinationDirectory.appendingPathComponent(file.relativePath)
            if file.source.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path {
                copiedAny = true
                continue
            }
            guard FileManager.default.fileExists(atPath: file.source.path) else {
                missing.append(file.relativePath)
                continue
            }
            do {
                try AssetImportFileCopier.copyReplacing(source: file.source, destination: target)
                copiedAny = true
            } catch {
                failures.append("\(file.relativePath): \(error)")
            }
        }
        return (copiedAny, missing, failures)
    }
}
