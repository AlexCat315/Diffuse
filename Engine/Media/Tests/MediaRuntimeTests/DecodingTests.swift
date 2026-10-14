import Foundation
import Testing
@testable import MediaRuntime

private func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name) }

@Test func pcmResamplingDrainsTailAndEnforcesResidentLimit() throws {
    let pcm = try AudioFile.decode(fixture("tone.wav"))
    #expect(pcm.channels == 2 && pcm.sampleRate == 48000)
    #expect(pcm.frameCount == 12000)
    #expect(pcm.samples.contains { $0 != 0 })
    #expect(throws: (any Error).self) { try AudioFile.decode(fixture("tone.wav"), maximumBytes: 100) }
    #expect(throws: (any Error).self) { try AudioFile.decode(fixture("video.mp4")) }
}

@Test func compressedAudioDecodesWithoutAnExternalProcess() async throws {
    let info = try MediaAsset.inspect(fixture("tone.m4a"))
    #expect(info.hasAudio && info.video == nil)
    let reader = try AudioReader(url: fixture("tone.m4a"))
    var frames = 0
    while let buffer = try await reader.nextBuffer() { frames += buffer.frameCount }
    #expect(frames >= 12000)
    try await reader.seek(to: 0)
    #expect(try await reader.nextBuffer() != nil)
}

@Test func videoFramesSeekAndResetAfterEOF() async throws {
    let asset = try MediaAsset.inspect(fixture("video.mp4"))
    #expect(asset.video?.width == 16 && asset.video?.height == 16)
    #expect(abs(asset.duration - 1) < 0.01)
    let reader = try VideoReader(url: fixture("video.mp4"))
    var count = 0
    while let frame = try await reader.nextFrame() {
        #expect(frame.rgba.count == 16 * 16 * 4)
        #expect(frame.rgba[0] > 200 && frame.rgba[1] < 30)
        count += 1
    }
    #expect(count == 10)
    let frame = try #require(await reader.frame(at: 0.5))
    #expect(abs(frame.time - 0.5) < 0.01)
    #expect(throws: (any Error).self) { try MediaAsset.inspect(URL(string: "https://example.com/video.mp4")!) }
}

@Test func authoredCompositionRoundTripsWithoutPlaybackState() throws {
    var document = MediaComposition()
    document.clips = [.init(source: "video.mp4", start: 0.1, duration: 0.4)]
    try document.validate()
    let defaults = try JSONDecoder().decode(MediaComposition.self, from: Data("{}".utf8))
    #expect(defaults == MediaComposition())
    let partial = try JSONDecoder().decode(MediaComposition.Video.self, from: Data("{\"width\":1280}".utf8))
    #expect(partial.width == 1280 && partial.height == 1080 && partial.framesPerSecond == 30)
    let data = try JSONEncoder().encode(document)
    #expect(try JSONDecoder().decode(MediaComposition.self, from: data) == document)
    #expect(!String(decoding: data, as: UTF8.self).contains("decoder"))
    document.clips[0].source = "../video.mp4"
    #expect(throws: (any Error).self) { try document.validate() }
}

#if os(macOS) || os(Linux) || os(Windows)
@Test func trimsAndConcatenatesVideoWithSilentAudio() async throws {
    let root = fixture("video.mp4").deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("guava-media-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    var composition = MediaComposition()
    composition.video.width = 16; composition.video.height = 16; composition.video.framesPerSecond = 10
    composition.clips = [.init(source: "video.mp4", start: 0.1, duration: 0.3), .init(source: "video.mp4", start: 0.5, duration: 0.3)]
    let exporter = MediaExporter(executable: try FFmpegTools.executable())
    try await exporter.export(composition, projectRoot: root, to: output)
    let result = try MediaAsset.inspect(output)
    #expect(result.hasAudio && result.video != nil)
    #expect(abs(result.duration - 0.6) < 0.06)
    await #expect(throws: (any Error).self) { try await exporter.export(composition, projectRoot: root, to: output) }
}
#endif
