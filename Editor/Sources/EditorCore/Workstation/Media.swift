private import CoveFileSystem
import Foundation
import AudioRuntime
import MediaRuntime
import CoveUICompose

public final class EditorMediaWorkspace: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<EditorMediaWorkspace>()
    private let root: URL
    private let documentURL: URL
    private var savedData: Data?
    public private(set) var composition = MediaComposition()
    public private(set) var isDirty = false
    public private(set) var error: String?
    public init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        documentURL = self.root.appendingPathComponent(".cove/media.json")
        if FileManager.default.fileExists(atPath: documentURL.path) {
            savedData = try Data(contentsOf: documentURL)
            composition = try JSONDecoder().decode(MediaComposition.self, from: savedData!)
            if !composition.clips.isEmpty { try composition.validate() }
        }
    }
    public func add(_ path: String) throws {
        let clip = MediaComposition.Clip(source: path, duration: 1)
        var candidate = MediaComposition(); candidate.clips = [clip]; try candidate.validate()
        let asset = try MediaAsset.inspect(try sourceURL(path))
        guard asset.video != nil, asset.duration > 0 else { throw MediaError.invalid("Select a video file with a known duration") }
        composition.clips.append(.init(source: path, duration: asset.duration))
        isDirty = true; publish()
    }
    public func trim(_ index: Int, start: Double, duration: Double) throws {
        guard composition.clips.indices.contains(index) else { return }
        var candidate = composition
        candidate.clips[index].start = start; candidate.clips[index].duration = duration
        try candidate.validate()
        let asset = try MediaAsset.inspect(try sourceURL(candidate.clips[index].source))
        guard start + duration <= asset.duration + 0.001 else { throw MediaError.invalid("Trim range exceeds the source duration") }
        composition = candidate; isDirty = true; publish()
    }
    public func remove(_ index: Int) {
        guard composition.clips.indices.contains(index) else { return }
        composition.clips.remove(at: index); isDirty = true; publish()
    }
    public func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard composition.clips.indices.contains(index), composition.clips.indices.contains(destination) else { return }
        composition.clips.swapAt(index, destination); isDirty = true; publish()
    }
    @discardableResult public func save() -> Bool {
        do {
            if !composition.clips.isEmpty { try composition.validate() }
            try FileManager.default.createDirectory(at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let current = FileManager.default.fileExists(atPath: documentURL.path) ? try Data(contentsOf: documentURL) : nil
            guard current == savedData else { throw MediaError.invalid("The media timeline changed on disk; reopen the project before saving") }
            let data = try encoder.encode(composition)
            try AtomicFile.write(data, to: documentURL)
            savedData = data
            isDirty = false; error = nil
        } catch { self.error = error.localizedDescription }
        publish(); return error == nil
    }
    public func preview(_ index: Int, at offset: Double = 0) async throws -> VideoFrame? {
        guard composition.clips.indices.contains(index) else { return nil }
        let clip = composition.clips[index]
        return try await VideoReader(url: try sourceURL(clip.source)).frame(at: clip.start + min(clip.duration, max(0, offset)))
    }
    public func play(_ index: Int, onVideo: @escaping @Sendable (VideoFrame) async -> Void) async throws {
        guard composition.clips.indices.contains(index) else { return }
        let clip = composition.clips[index]
        try await MediaPlayer().play(url: try sourceURL(clip.source), from: clip.start,
                                    duration: clip.duration, onVideo: onVideo)
    }
    public func export(to output: URL, executable: URL) async throws {
        try await MediaExporter(executable: executable).export(composition, projectRoot: root, to: output)
    }
    private func sourceURL(_ path: String) throws -> URL {
        var candidate = MediaComposition(); candidate.clips = [.init(source: path, duration: 1)]
        try candidate.validate()
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MediaError.invalid("Media source must remain inside the project")
            }
        }
        return url
    }
    private func publish() { publisher.send() }
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    public func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
