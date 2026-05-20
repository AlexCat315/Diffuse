import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Loaded audio asset ready for playback.
public final class AudioClipResource: @unchecked Sendable {
    public let name: String
    let buffer: AVAudioPCMBuffer

    public init(name: String, buffer: AVAudioPCMBuffer) {
        self.name = name
        self.buffer = buffer
    }

    public static func load(name: String, url: URL) -> AudioClipResource? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        guard (try? file.read(into: buffer)) != nil else { return nil }
        buffer.frameLength = frameCount
        return AudioClipResource(name: name, buffer: buffer)
    }
}
#else
/// Stub for platforms without AVFoundation.
public final class AudioClipResource: @unchecked Sendable {
    public let name: String
    public init(name: String) { self.name = name }
    public static func load(name: String, url: URL) -> AudioClipResource? { nil }
}
#endif
