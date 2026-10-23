import Foundation
import PluginRuntime

/// Cross-platform monitor for changes to enabled plugin packages.
///
/// Polling is intentional, mirroring `ScriptDirectoryMonitor`: builds replace
/// package files atomically, which invalidates file-descriptor watchers, and a
/// snapshot behaves consistently on macOS, Linux, and Windows. Watching is
/// opt-in (`--watch-plugins` / `GUAVA_WATCH_PLUGINS`) and never authorizes a
/// changed package on its own.
final class PluginPackageMonitor: @unchecked Sendable {
    private struct Entry: Equatable {
        struct File: Equatable {
            var size: UInt64
            var modificationTime: TimeInterval
        }
        var files: [String: File]
    }

    private let queue = DispatchQueue(label: "com.guava.editor.plugin-package-monitor",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var packages: [String: URL] = [:]
    private var previousSnapshot: [String: Entry] = [:]

    /// Starts polling. `onChange` delivers the changed plugin ids on the main
    /// queue, at most once per observed change until the files change again.
    func start(interval: TimeInterval = 1.0,
               onChange: @escaping @Sendable ([String]) -> Void) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.previousSnapshot = self.snapshot()
            let boundedInterval = interval.isFinite ? min(3_600, max(0.25, interval)) : 1
            let clampedMilliseconds = Int(boundedInterval * 1_000)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(clampedMilliseconds),
                           repeating: .milliseconds(clampedMilliseconds),
                           leeway: .milliseconds(120))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let next = self.snapshot()
                guard next != self.previousSnapshot else { return }
                let changed = Set(next.keys)
                    .union(self.previousSnapshot.keys)
                    .filter { next[$0] != self.previousSnapshot[$0] }
                    .sorted()
                self.previousSnapshot = next
                guard !changed.isEmpty else { return }
                DispatchQueue.main.async { onChange(changed) }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Replaces the watched package set and rebases the snapshot, so binding
    /// changes themselves are never reported as file changes.
    func setPackages(_ packages: [String: URL]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.packages = packages
            self.previousSnapshot = self.snapshot()
        }
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func snapshot() -> [String: Entry] {
        var result: [String: Entry] = [:]
        for (pluginID, url) in packages {
            var files: [String: Entry.File] = [:]
            let manifest = try? Data(contentsOf: url.appendingPathComponent("plugin.json"))
            let resources = manifest.flatMap { try? JSONDecoder().decode(GuavaPluginManifest.self, from: $0) }?
                .resources.map(\.path).filter(PluginResource.isValidPath) ?? []
            for name in ["plugin.json", "capabilities.wit", "component.wasm"] + resources {
                let fileURL = url.appendingPathComponent(name)
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                ), let size = values.fileSize,
                   let modified = values.contentModificationDate else { continue }
                files[name] = Entry.File(size: UInt64(size),
                                         modificationTime: modified.timeIntervalSince1970)
            }
            result[pluginID] = Entry(files: files)
        }
        return result
    }
}
