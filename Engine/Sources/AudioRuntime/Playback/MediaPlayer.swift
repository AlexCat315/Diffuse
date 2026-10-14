import CSDL3
import Foundation
import MediaRuntime

/// Streams video and audio without retaining the whole movie. Cancelling the
/// calling task stops playback and releases decoder/device state.
public actor MediaPlayer {
    public init() {}

    public func play(url: URL, from start: Double = 0, duration: Double? = nil,
                     onVideo: @escaping @Sendable (VideoFrame) async -> Void) async throws {
        guard start.isFinite, start >= 0, duration == nil || (duration!.isFinite && duration! > 0) else {
            throw MediaError.invalid("Playback range must be finite and positive")
        }
        let asset = try MediaAsset.inspect(url)
        let end = min(asset.duration, start + (duration ?? asset.duration))
        guard asset.video != nil, start < end else { throw MediaError.invalid("Playback requires a video stream and a valid range") }
        let video = try VideoReader(url: url)
        try await video.seek(to: start)
        let audio = asset.hasAudio ? try AudioReader(url: url) : nil
        try await audio?.seek(to: start)
        let sink = audio == nil ? nil : try PlaybackAudioSink()
        var audioEnded = audio == nil
        var submitted: Double = 0
        var frame = try await video.nextFrame()
        let clock = ContinuousClock()
        var began: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            if let audio, let sink, !audioEnded {
                while sink.queuedSeconds < 0.2 && !audioEnded {
                    if let buffer = try await audio.nextBuffer() {
                        let remainingFrames = max(0, Int(((end - start) - submitted) * 48000))
                        let frames = min(buffer.frameCount, remainingFrames)
                        try sink.write(buffer.samples.prefix(frames * 8))
                        submitted += Double(frames) / 48000
                        if frames < buffer.frameCount || remainingFrames == 0 { audioEnded = true; sink.flush() }
                    } else { audioEnded = true; sink.flush() }
                }
            }
            if began == nil { try sink?.resume(); began = clock.now }
            let elapsed = began!.duration(to: clock.now).components
            let wallTime = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            // After a shorter audio track ends, the movie continues on its clock.
            let played = sink != nil && (!audioEnded || sink!.queuedSeconds > 0)
                ? max(0, submitted - sink!.queuedSeconds) : wallTime
            let position = start + played
            if position >= end { break }
            if let pending = frame, pending.time < end, pending.time <= position + 0.005 {
                await onVideo(pending)
                frame = try await video.nextFrame()
            }
            try await clock.sleep(for: .milliseconds(5))
        }
    }
}

private final class PlaybackAudioSink {
    private let stream: OpaquePointer
    private let outputBytesPerSecond: Double
    init() throws {
        guard SDL_InitSubSystem(GUAVA_SDL_INIT_AUDIO) else { throw MediaError.decoding("Audio device initialization failed") }
        var spec = SDL_AudioSpec(); spec.freq = 48000; spec.channels = 2; spec.format = SDL_AUDIO_F32
        guard let stream = SDL_OpenAudioDeviceStream(GUAVA_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil) else {
            SDL_QuitSubSystem(GUAVA_SDL_INIT_AUDIO)
            throw MediaError.decoding("Audio output device is unavailable")
        }
        self.stream = stream
        var output = SDL_AudioSpec()
        _ = SDL_GetAudioDeviceFormat(SDL_GetAudioStreamDevice(stream), &output, nil)
        outputBytesPerSecond = Double(max(1, output.freq)) * Double(max(1, output.channels)) * Double(max(1, Int(output.format.rawValue & 0xFF) / 8))
    }
    deinit { SDL_DestroyAudioStream(stream); SDL_QuitSubSystem(GUAVA_SDL_INIT_AUDIO) }
    var queuedSeconds: Double {
        Double(max(0, SDL_GetAudioStreamQueued(stream))) / (48000 * 8)
            + Double(max(0, SDL_GetAudioStreamAvailable(stream))) / outputBytesPerSecond
    }
    func write(_ samples: Data) throws {
        guard samples.withUnsafeBytes({ SDL_PutAudioStreamData(stream, $0.baseAddress, Int32($0.count)) }) else {
            throw MediaError.decoding("Audio stream rejected decoded samples")
        }
    }
    func flush() { _ = SDL_FlushAudioStream(stream) }
    func resume() throws {
        guard SDL_ResumeAudioStreamDevice(stream) else { throw MediaError.decoding("Audio device failed to resume") }
    }
}
