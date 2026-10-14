import Foundation

public enum MediaError: Error, LocalizedError, Sendable {
    case invalid(String)
    case decoding(String)
    case export(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .decoding(let s), .export(let s): s }
    }
}

/// Interleaved, native Float32 stereo PCM at 48 kHz, ready for an audio sink.
public struct PCMBuffer: Sendable {
    public let samples: Data
    public var sampleRate: Int { 48000 }
    public var channels: Int { 2 }
    public var frameCount: Int { samples.count / (2 * MemoryLayout<Float>.size) }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
    init(samples: Data) { self.samples = samples }
}

public struct VideoFrame: Sendable {
    public let rgba: Data
    public let width: Int
    public let height: Int
    public let stride: Int
    public let time: Double
}

public struct MediaAsset: Sendable {
    public struct Video: Sendable {
        public let width: Int
        public let height: Int
    }
    public let duration: Double
    public let video: Video?
    public let hasAudio: Bool

    public static func inspect(_ url: URL) throws -> Self {
        let audio = try? FileDecoder(url: url, video: false)
        let video = try? FileDecoder(url: url, video: true)
        guard audio != nil || video != nil else { throw MediaError.decoding("No supported media streams: \(url.lastPathComponent)") }
        return Self(duration: max(audio?.info.duration ?? 0, video?.info.duration ?? 0),
                    video: video.map { Video(width: Int($0.info.width), height: Int($0.info.height)) },
                    hasAudio: audio != nil)
    }
}
