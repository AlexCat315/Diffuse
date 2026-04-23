import Foundation
import SequenceRuntime
import Testing

@Suite("SequenceRuntime")
struct SequenceRuntimeTests {
    @Test("clip scheduler maps sequence frame into shot and source time")
    func clipSchedulerMapsFrames() {
        let clip = Clip(id: "clip.anim",
                        name: "Hero Walk",
                        shotRange: FrameRange(start: 10, end: 20),
                        sourceOffset: 40,
                        timeWarp: 2.0)
        let track = Track(id: "track.anim", name: "Animation", kind: .animation, clips: [clip])
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 100, end: 160),
                        sourceOffset: 8,
                        cameraBinding: cameraBinding(),
                        tracks: [track])

        let scheduled = ClipScheduler.activeClips(in: shot, at: 104)

        #expect(scheduled.count == 1)
        #expect(scheduled[0].shotID == "shot.a")
        #expect(scheduled[0].trackID == "track.anim")
        #expect(scheduled[0].shotFrame == 12)
        #expect(scheduled[0].sourceFrame == 44)
    }

    @Test("clip scheduler treats zero time warp as a hold")
    func zeroTimeWarpHoldsFirstSourceFrame() {
        let clip = Clip(id: "clip.hold",
                        name: "Hold",
                        shotRange: FrameRange(start: 0, end: 10),
                        sourceOffset: 18,
                        timeWarp: 0)
        let track = Track(id: "track.anim", name: "Animation", kind: .animation, clips: [clip])
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 0, end: 20),
                        cameraBinding: cameraBinding(),
                        tracks: [track])

        let scheduled = ClipScheduler.activeClips(in: shot, at: 6)

        #expect(scheduled.count == 1)
        #expect(scheduled[0].sourceFrame == 18)
    }

    @Test("shot evaluator honors mute and solo filtering")
    func evaluatorHonorsMuteAndSolo() {
        let clipA = Clip(id: "clip.a", name: "A", shotRange: FrameRange(start: 0, end: 10))
        let clipB = Clip(id: "clip.b", name: "B", shotRange: FrameRange(start: 0, end: 10))
        let trackA = Track(id: "track.a",
                           name: "Animation",
                           kind: .animation,
                           mute: true,
                           clips: [clipA])
        let trackB = Track(id: "track.b",
                           name: "Camera",
                           kind: .camera,
                           clips: [clipB])
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 0, end: 20),
                        cameraBinding: cameraBinding(),
                        tracks: [trackA, trackB])
        let sequence = SequenceDocument(name: "Test",
                                        sceneDocumentURI: "scene://main",
                                        frameRange: FrameRange(start: 0, end: 20),
                                        shots: [shot])

        let evaluated = ShotEvaluator.evaluate(sequence,
                                               at: 5,
                                               options: SequenceEvaluationOptions(soloTrackIDs: ["track.b"]))

        #expect(evaluated.shot?.shotID == "shot.a")
        #expect(evaluated.activeClips.count == 1)
        #expect(evaluated.activeClips[0].trackID == "track.b")
    }

    @Test("shot evaluator reports active markers and cut progress")
    func evaluatorReportsMarkersAndCutProgress() {
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 20, end: 60),
                        cameraBinding: cameraBinding())
        let marker = Marker(id: "marker.sync",
                            frame: 24,
                            kind: .syncPoint,
                            label: "beat")
        let cut = Cut(id: "cut.dissolve",
                      frame: 24,
                      transition: .dissolve,
                      duration: 6)
        let sequence = SequenceDocument(name: "Test",
                                        sceneDocumentURI: "scene://main",
                                        frameRange: FrameRange(start: 0, end: 60),
                                        shots: [shot],
                                        markers: [marker],
                                        cuts: [cut])

        let atMarker = ShotEvaluator.evaluate(sequence, at: 24)
        let duringCut = ShotEvaluator.evaluate(sequence, at: 27)

        #expect(atMarker.activeMarkers.map(\ .id) == ["marker.sync"])
        #expect(duringCut.activeCut?.cut.id == "cut.dissolve")
        #expect(abs((duringCut.activeCut?.progress ?? 0) - 0.5) < 0.000_1)
    }

    @Test("fps remap supports duration ratio and frame count modes")
    func fpsRemapSupportsMultipleModes() {
        let original = FrameRange(start: 0, end: 48)
        let source = TimeBase(fps: 24)
        let destination = TimeBase(fps: 30)

        let ratio = ClipScheduler.remapFrameRange(original,
                                                  from: source,
                                                  to: destination,
                                                  mode: .preserveDurationRatio)
        let frameCount = ClipScheduler.remapFrameRange(original,
                                                       from: source,
                                                       to: destination,
                                                       mode: .preserveFrameCount)

        #expect(ratio == FrameRange(start: 0, end: 60))
        #expect(frameCount == original)
    }

    @Test("track Codable omits solo and lock session state")
    func trackCodableOmitsSessionState() throws {
        let track = Track(id: "track.a",
                          name: "Animation",
                          kind: .animation,
                          solo: true,
                          lock: true,
                          colorToken: "cyan")

        let data = try JSONEncoder().encode(track)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(Track.self, from: data)

        #expect(!json.contains("solo"))
        #expect(!json.contains("lock"))
        #expect(decoded.solo == false)
        #expect(decoded.lock == false)
        #expect(decoded.colorToken == "cyan")
    }

    private func cameraBinding() -> Binding {
        Binding(id: "binding.camera",
                abstractRole: "main_camera",
                resolvedTarget: SceneTargetReference(docURI: "scene://main",
                                                     targetID: "camera.main"),
                resolutionStatus: .bound)
    }
}