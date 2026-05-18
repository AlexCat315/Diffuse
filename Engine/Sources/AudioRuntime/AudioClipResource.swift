import Foundation
import AVFoundation

/// Loaded audio asset ready for playback.
public final class AudioClipResource: @unchecked Sendable {
    public let name: String
    let buffer: AVAudioPCMBuffer

    public init(name: String, buffer: AVAudioPCMBuffer) {
        self.name = name
        self.buffer = buffer
    }

    /// Load a clip from a file URL. Returns nil if the file cannot be decoded.
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
