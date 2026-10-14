import Foundation

/// Streaming reader; independent files and tracks do not share decoder state.
public actor VideoReader {
    private let decoder: FileDecoder
    public init(url: URL) throws { decoder = try FileDecoder(url: url, video: true) }
    public func nextFrame() throws -> VideoFrame? { try decoder.video() }
    public func seek(to seconds: Double) throws { try decoder.seek(to: seconds) }
    public func frame(at seconds: Double) throws -> VideoFrame? {
        try decoder.seek(to: seconds)
        return try decoder.video()
    }
}

public actor AudioReader {
    private let decoder: FileDecoder
    public init(url: URL) throws { decoder = try FileDecoder(url: url, video: false) }
    public func nextBuffer() throws -> PCMBuffer? { try decoder.audio() }
    public func seek(to seconds: Double) throws { try decoder.seek(to: seconds) }
}

public enum AudioFile {
    /// Bounded resident clips for SFX. Long media should use AudioReader.
    public static func decode(_ url: URL, maximumBytes: Int = 128 * 1024 * 1024) throws -> PCMBuffer {
        guard maximumBytes > 0 else { throw MediaError.invalid("PCM byte limit must be positive") }
        let decoder = try FileDecoder(url: url, video: false)
        var samples = Data()
        while let chunk = try decoder.audio() {
            guard chunk.samples.count <= maximumBytes - samples.count else {
                throw MediaError.invalid("Decoded audio exceeds the resident clip limit; use AudioReader for streaming")
            }
            samples.append(chunk.samples)
        }
        guard !samples.isEmpty else { throw MediaError.decoding("Audio stream contains no samples") }
        return PCMBuffer(samples: samples)
    }
}
