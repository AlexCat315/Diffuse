import Foundation

/// Cross-platform monitor for externally-created, renamed, edited, or deleted
/// top-level Swift files in a project's Scripts directory.
///
/// Polling is intentional here: editor writes commonly replace a file
/// atomically, which invalidates file-descriptor watchers. A directory snapshot
/// also behaves consistently on macOS, Linux, and Windows.
final class ScriptDirectoryMonitor: @unchecked Sendable {
    private struct Entry: Equatable {
        var size: UInt64
        var modificationTime: TimeInterval
    }

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.guava.editor.script-directory-monitor",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousSnapshot: [String: Entry] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.previousSnapshot = self.snapshot()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(650),
                           repeating: .milliseconds(650),
                           leeway: .milliseconds(120))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let next = self.snapshot()
                guard next != self.previousSnapshot else { return }
                self.previousSnapshot = next
                onChange()
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

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func snapshot() -> [String: Entry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [String: Entry] = [:]
        for url in urls where url.pathExtension.lowercased() == "swift" {
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            result[url.lastPathComponent] = Entry(
                size: UInt64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        return result
    }
}
