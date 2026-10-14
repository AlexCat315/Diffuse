import AudioRuntime
import Foundation
import MediaRuntime
import Testing

private actor PlaybackFrames {
    var times: [Double] = []
    func append(_ time: Double) { times.append(time) }
}

private var playbackFixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Media/Tests/MediaRuntimeTests/Fixtures/video.mp4")
}

@Test func videoPlaybackRespectsRangeAndCancellation() async throws {
    let frames = PlaybackFrames()
    let start = ContinuousClock.now
    try await MediaPlayer().play(url: playbackFixture, from: 0.2, duration: 0.2) { frame in await frames.append(frame.time) }
    let times = await frames.times
    #expect(times.count == 2)
    #expect(zip(times, [0.2, 0.3]).allSatisfy { abs($0 - $1) < 0.000001 })
    #expect(start.duration(to: .now) >= .milliseconds(180))
    let task = Task { try await MediaPlayer().play(url: playbackFixture) { _ in } }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
