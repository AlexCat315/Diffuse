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
                requestImportFiles(paths, app: app, into: folder)
            }
        }
    }

    static func importDestination(app: EditorApplication, folder: String) -> String {
        let base = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
        return folder.isEmpty ? base.path : base.appendingPathComponent(folder, isDirectory: true).path
    }

    private struct ImportBatch: Sendable {
        var names: [String] = []
        var missing: [String] = []
        var failures: [String] = []
        var unsupported: [String] = []
    }

    static func requestImportFiles(_ paths: [String], app: EditorApplication, into folder: String) {
        guard !paths.isEmpty, app.isActive,
              !app.store.operations.contains(where: { $0.kind == .importing && $0.status == .running }) else { return }
        let destination = URL(fileURLWithPath: importDestination(app: app, folder: folder), isDirectory: true)
        let operation = app.beginOperation(.importing, message: L("Importing assets…"), total: paths.count)
        Task.detached(priority: .userInitiated) { [weak app] in
            let batch = copyBatch(paths, destination: destination)
            await MainActor.run {
                guard let app, app.isActive else { return }
                completeBatch(batch, destination: destination, app: app, operation: operation)
            }
        }
    }

    /// Synchronous entry point for automation; desktop pickers use the background path.
    static func importFiles(_ paths: [String], app: EditorApplication, into folder: String) {
        guard !paths.isEmpty else { return }
        let destination = URL(fileURLWithPath: importDestination(app: app, folder: folder), isDirectory: true)
        let operation = app.beginOperation(.importing, message: L("Importing assets…"), total: paths.count)
        completeBatch(copyBatch(paths, destination: destination), destination: destination,
                      app: app, operation: operation)
    }

    private static func copyBatch(_ paths: [String], destination: URL) -> ImportBatch {
        var batch = ImportBatch()
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { batch.failures = [String(describing: error)]; return batch }
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard AssetImportResolver.isSupported(source) else {
                batch.unsupported.append(source.lastPathComponent); continue
            }
            let outcome = copyAsset(from: source, into: destination)
            if outcome.copied { batch.names.append(source.lastPathComponent) }
            batch.missing.append(contentsOf: outcome.missing)
            batch.failures.append(contentsOf: outcome.failures)
        }
        return batch
    }

    private static func completeBatch(_ batch: ImportBatch, destination: URL,
                                       app: EditorApplication, operation: String) {
        var reloaded = true
        if !batch.names.isEmpty {
            let count = app.reloadAssets()
            reloaded = count != nil
            AssetThumbnailRasterizer.invalidate()
            ImageAssetRegistryHolder.current?.clear()
            if let count {
                app.logConsole("Imported \(batch.names.count) asset\(batch.names.count == 1 ? "" : "s")",
                    detail: "\(batch.names.joined(separator: ", ")) · \(count) assets in catalog")
            } else {
                app.logConsole("Asset files were copied but the catalog could not reload", severity: .warning,
                    detail: batch.names.joined(separator: ", "),
                    nextStep: "Check the asset format and dependencies, then Reload Assets.")
            }
        }
        for path in batch.missing {
            app.logConsole("Asset imported with missing dependencies", severity: .warning, detail: path,
                target: .file(path: destination.appendingPathComponent(path).path),
                nextStep: "Locate the missing file in Assets and use Repair Missing Resource.")
        }
        if !batch.failures.isEmpty {
            app.logConsole("Failed to import asset files", severity: .error,
                detail: batch.failures.joined(separator: ", "), target: .file(path: destination.path),
                nextStep: "Check file permissions and free space, then import again.")
        }
        if !batch.unsupported.isEmpty {
            app.logConsole("Unsupported format — import models or textures", severity: .warning,
                detail: batch.unsupported.joined(separator: ", "),
                nextStep: "Convert the files to a supported model or texture format, then import again.")
        }
        let success = reloaded && !batch.names.isEmpty && batch.failures.isEmpty && batch.missing.isEmpty && batch.unsupported.isEmpty
        app.finishOperation(operation, succeeded: success,
            message: success ? L("Asset import complete") : L("Asset import needs attention"),
            nextStep: success ? nil : "Open Problems, repair the reported files, then Reload Assets.",
            target: success ? nil : .file(path: destination.path))
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
