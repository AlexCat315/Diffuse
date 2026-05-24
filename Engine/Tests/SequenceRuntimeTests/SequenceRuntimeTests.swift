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

    @Test("override resolver returns blend weights at shot boundaries")
    func overrideResolverBlendWeight() {
        let override = ShotOverride(
            id: "ov.brightness",
            targetKind: .lightParam,
            targetRef: SceneTargetReference(docURI: "scene://main", targetID: "light.key",
                                            subPath: "intensity"),
            valueKind: .absolute,
            value: .number(2.5),
            blendInFrames: 10,
            blendOutFrames: 10,
            ease: .linear
        )
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 100, end: 160),
                        cameraBinding: cameraBinding(),
                        overrides: [override])

        let atStart = OverrideResolver.activeOverrides(in: shot, at: 100)
        let midBlendIn = OverrideResolver.activeOverrides(in: shot, at: 105)
        let fullyOn = OverrideResolver.activeOverrides(in: shot, at: 120)
        let midBlendOut = OverrideResolver.activeOverrides(in: shot, at: 155)
        let outsideShot = OverrideResolver.activeOverrides(in: shot, at: 160)

        #expect(atStart.count == 0)
        #expect(midBlendIn.count == 1)
        #expect(abs(midBlendIn[0].weight - 0.5) < 0.001)
        #expect(fullyOn.count == 1)
        #expect(abs(fullyOn[0].weight - 1.0) < 0.001)
        #expect(midBlendOut.count == 1)
        #expect(abs(midBlendOut[0].weight - 0.5) < 0.001)
        #expect(outsideShot.count == 0)
    }

    @Test("cache strict policy invalidates on revision mismatch")
    func cacheStrictPolicyInvalidatesOnRevisionMismatch() {
        let bakedRevision = SequenceRevision(id: "rev-001")
        let currentRevision = SequenceRevision(id: "rev-002")

        let strictCache = SequenceCache(id: "cache.physics",
                                        kind: .physics,
                                        shotID: "shot.a",
                                        range: FrameRange(start: 0, end: 60),
                                        storageURI: "cache://physics.bin",
                                        sourceRevision: bakedRevision,
                                        invalidationPolicy: .strict)

        let tolerantCache = SequenceCache(id: "cache.cloth",
                                          kind: .cloth,
                                          shotID: "shot.a",
                                          range: FrameRange(start: 0, end: 60),
                                          storageURI: "cache://cloth.bin",
                                          sourceRevision: bakedRevision,
                                          invalidationPolicy: .tolerant)

        let strictResult = CacheValidator.validate(strictCache, currentRevision: currentRevision)
        let tolerantResult = CacheValidator.validate(tolerantCache, currentRevision: currentRevision)
        let freshStrict = CacheValidator.validate(strictCache,
                                                  currentRevision: bakedRevision)

        #expect(strictResult.isValid == false)
        #expect(strictResult.isStale == true)
        #expect(tolerantResult.isValid == true)
        #expect(tolerantResult.isStale == true)
        #expect(freshStrict.isValid == true)
        #expect(freshStrict.isStale == false)
    }

    @Test("binding validator blocks render when bindings are not bound")
    func bindingValidatorBlocksRenderWhenUnbound() {
        let boundBinding = Binding(id: "binding.hero",
                                   abstractRole: "main_character",
                                   resolvedTarget: SceneTargetReference(docURI: "scene://main",
                                                                        targetID: "entity.hero"),
                                   resolutionStatus: .bound)
        let staleBinding = Binding(id: "binding.prop",
                                   abstractRole: "hero_prop",
                                   resolutionStatus: .stale)

        let clip = Clip(id: "clip.anim",
                        name: "Hero Walk",
                        shotRange: FrameRange(start: 0, end: 24),
                        bindings: [boundBinding, staleBinding])
        let track = Track(id: "track.anim", name: "Animation", kind: .animation, clips: [clip])
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 0, end: 60),
                        cameraBinding: cameraBinding(),
                        tracks: [track])
        let sequence = SequenceDocument(name: "Test",
                                        sceneDocumentURI: "scene://main",
                                        frameRange: FrameRange(start: 0, end: 60),
                                        shots: [shot])

        let result = BindingValidator.validateForRender(sequence)
        guard case let .blocked(ids) = result else {
            Issue.record("expected .blocked but got .ok")
            return
        }
        #expect(ids.contains("binding.prop"))
        #expect(!ids.contains("binding.hero"))
    }

    @Test("document-level FPS remap scales all frame ranges proportionally")
    func documentFPSRemapScalesAllRanges() {
        let clip = Clip(id: "clip.anim",
                        name: "Hero Walk",
                        shotRange: FrameRange(start: 0, end: 24),
                        blendInFrames: 6)
        let track = Track(id: "track.anim", name: "Animation", kind: .animation, clips: [clip])
        let shot = Shot(id: "shot.a",
                        name: "sc010_sh020",
                        range: FrameRange(start: 0, end: 48),
                        cameraBinding: cameraBinding(),
                        tracks: [track])
        let cut = Cut(id: "cut.dissolve",
                      frame: 24,
                      transition: .dissolve,
                      duration: 12)
        let marker = Marker(id: "marker.beat", frame: 12, kind: .syncPoint, label: "beat")
        let sequence = SequenceDocument(name: "Test",
                                        sceneDocumentURI: "scene://main",
                                        frameRange: FrameRange(start: 0, end: 48),
                                        shots: [shot],
                                        markers: [marker],
                                        cuts: [cut])

        let remapped = sequence.remapping(from: 24, to: 30, mode: .preserveDurationRatio)

        #expect(remapped.timeBase.fps == 30)
        #expect(remapped.frameRange == FrameRange(start: 0, end: 60))
        #expect(remapped.shots[0].range == FrameRange(start: 0, end: 60))
        #expect(remapped.shots[0].tracks[0].clips[0].shotRange == FrameRange(start: 0, end: 30))
        #expect(remapped.shots[0].tracks[0].clips[0].blendInFrames == 8)
        #expect(remapped.cuts[0].frame == 30)
        #expect(remapped.cuts[0].duration == 15)
        #expect(remapped.markers[0].frame == 15)
    }

    private func cameraBinding() -> Binding {
        Binding(id: "binding.camera",
                abstractRole: "main_camera",
                resolvedTarget: SceneTargetReference(docURI: "scene://main",
                                                     targetID: "camera.main"),
                resolutionStatus: .bound)
    }
}