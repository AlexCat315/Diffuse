#if os(macOS) || os(Linux) || os(Windows)
import Foundation

/// Desktop render worker. FFmpeg receives argv directly; authored paths never enter shell code.
public actor MediaExporter {
    private let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func export(_ composition: MediaComposition, projectRoot: URL, to output: URL) throws {
        try composition.validate()
        guard output.isFileURL, output.pathExtension.lowercased() == "mp4" else { throw MediaError.invalid("Export destination must be a local .mp4 file") }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw MediaError.export("Export destination already exists") }
        let args = try ExportPlan.arguments(composition, root: projectRoot)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".guava-\(UUID().uuidString).mp4")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("guava-media-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: log); try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n"] + args + [temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? Data(contentsOf: log)).map { String(decoding: $0.suffix(8192), as: UTF8.self) } ?? "FFmpeg failed"
            throw MediaError.export(message)
        }
        try FileManager.default.moveItem(at: temporary, to: output)
    }
}

enum ExportPlan {
    static func arguments(_ composition: MediaComposition, root: URL) throws -> [String] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var inputs: [String] = [], filters: [String] = [], outputs: [String] = []
        let video = composition.video
        for (index, clip) in composition.clips.enumerated() {
            let url = root.appendingPathComponent(clip.source).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw MediaError.invalid("Media source escapes project root") }
            let asset = try MediaAsset.inspect(url)
            guard asset.video != nil, asset.duration >= clip.start + clip.duration - 0.05 else {
                throw MediaError.invalid("Clip range exceeds video source: \(clip.source)")
            }
            inputs += ["-i", url.path]
            filters.append("[\(index):v]trim=start=\(clip.start):duration=\(clip.duration),setpts=PTS-STARTPTS,scale=\(video.width):\(video.height):force_original_aspect_ratio=decrease,pad=\(video.width):\(video.height):(ow-iw)/2:(oh-ih)/2,fps=\(video.framesPerSecond),format=yuv420p[v\(index)]")
            if asset.hasAudio {
                filters.append("[\(index):a]atrim=start=\(clip.start):duration=\(clip.duration),asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            } else {
                filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(clip.duration)[a\(index)]")
            }
            outputs.append("[v\(index)][a\(index)]")
        }
        filters.append(outputs.joined() + "concat=n=\(composition.clips.count):v=1:a=1[v][a]")
        return inputs + ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                         "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
    }
}
#endif
