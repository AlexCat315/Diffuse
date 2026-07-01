import EditorCore
import Foundation
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorViewportRenderGate")
struct EditorViewportRenderGateTests {
    private func signature(revision: UInt64 = 1,
                           eyeX: Float = 0,
                           width: UInt32 = 1000,
                           settings: UInt64 = 0,
                           paletteCount: Int = 0) -> EditorViewportRenderGate.Signature {
        var palettes: [EntityID: JointPalette] = [:]
        for index in 0..<paletteCount {
            palettes[EntityID(index: UInt32(index), generation: 0)] =
                JointPalette(matrices: [matrix_identity_float4x4])
        }
        return EditorViewportRenderGate.Signature(
            sceneRevision: revision,
            camera: RenderCamera(eye: SIMD3<Float>(eyeX, 2, 5)),
            drawableSize: RenderDrawableSize(width: width, height: 800),
            settingsGeneration: settings,
            jointPalettes: JointPaletteMap(palettes: palettes)
        )
    }

    private func decide(_ gate: inout EditorViewportRenderGate,
                        _ sig: EditorViewportRenderGate.Signature,
                        force: Bool = false,
                        input: Bool = false,
                        taa: Bool = false,
                        now: Double) -> Bool {
        gate.shouldRender(signature: sig,
                          forceContinuous: force,
                          hasViewportInput: input,
                          temporalEffectsActive: taa,
                          now: now)
    }

    /// Steps the gate through enough clean ticks to drain the post-dirty
    /// convergence frames, then returns the next clean decision.
    private func settled(_ gate: inout EditorViewportRenderGate,
                         _ sig: EditorViewportRenderGate.Signature,
                         at time: Double) -> Bool {
        for _ in 0..<EditorViewportRenderGate.temporalConvergenceFrames {
            _ = decide(&gate, sig, now: time)
        }
        return decide(&gate, sig, now: time)
    }

    @Test("First tick renders, identical follow-ups settle into skipping")
    func settlesWhenClean() {
        var gate = EditorViewportRenderGate()
        let sig = signature()
        let first = decide(&gate, sig, now: 0)
        #expect(first)
        let afterSettle = settled(&gate, sig, at: 0.1)
        #expect(!afterSettle)
        let stillClean = decide(&gate, sig, now: 0.2)
        #expect(!stillClean)
    }

    @Test("Each packet input change re-renders: revision, camera, size, settings, palettes")
    func packetInputChangesDirty() {
        var gate = EditorViewportRenderGate()
        _ = settled(&gate, signature(), at: 0)

        for changed in [signature(revision: 2),
                        signature(revision: 2, eyeX: 1),
                        signature(revision: 2, eyeX: 1, width: 1400),
                        signature(revision: 2, eyeX: 1, width: 1400, settings: 1),
                        signature(revision: 2, eyeX: 1, width: 1400, settings: 1, paletteCount: 1)] {
            let rendered = decide(&gate, changed, now: 0.1)
            #expect(rendered)
            let settledAgain = settled(&gate, changed, at: 0.1)
            #expect(!settledAgain)
        }
    }

    @Test("Convergence renders a couple of frames after the last change, more with TAA")
    func convergenceFrames() {
        var gate = EditorViewportRenderGate()
        let sig = signature()
        let dirtyFrame = decide(&gate, sig, now: 0)
        #expect(dirtyFrame)
        // convergenceFrames = 2: the dirty frame plus one extra.
        let extraFrame = decide(&gate, sig, now: 0.01)
        #expect(extraFrame)
        let thirdFrame = decide(&gate, sig, now: 0.02)
        #expect(!thirdFrame)

        var taaGate = EditorViewportRenderGate()
        let taaDirty = decide(&taaGate, sig, taa: true, now: 0)
        #expect(taaDirty)
        var renderedAfterDirty = 0
        for tick in 0..<(EditorViewportRenderGate.temporalConvergenceFrames + 4) {
            if decide(&taaGate, sig, taa: true, now: 0.01 + Double(tick) * 0.01) {
                renderedAfterDirty += 1
            }
        }
        #expect(renderedAfterDirty == EditorViewportRenderGate.temporalConvergenceFrames - 1)
    }

    @Test("Realtime / playing force and viewport input keep rendering")
    func forcesKeepRendering() {
        var gate = EditorViewportRenderGate()
        let sig = signature()
        _ = settled(&gate, sig, at: 0)

        let forcedOnce = decide(&gate, sig, force: true, now: 0.1)
        #expect(forcedOnce)
        let forcedAgain = decide(&gate, sig, force: true, now: 0.2)
        #expect(forcedAgain)

        var inputGate = EditorViewportRenderGate()
        _ = settled(&inputGate, sig, at: 0)
        let inputFrame = decide(&inputGate, sig, input: true, now: 0.1)
        #expect(inputFrame)
    }

    @Test("Frame drive treats camera and gizmo drags as continuous work")
    func frameDriveIncludesContinuousViewportInteraction() {
        #expect(EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: false,
            playbackState: .stopped,
            sceneHasActiveParticles: false,
            continuousViewportInteractionActive: true
        ))
        #expect(!EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: false,
            playbackState: .stopped,
            sceneHasActiveParticles: false,
            continuousViewportInteractionActive: false
        ))
        #expect(EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: true,
            playbackState: .stopped,
            sceneHasActiveParticles: false,
            continuousViewportInteractionActive: false
        ))
        #expect(EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: false,
            playbackState: .playing,
            sceneHasActiveParticles: false,
            continuousViewportInteractionActive: false
        ))
        #expect(EditorViewportFrameDrive.wantsContinuousFrames(
            viewportRealtimeEnabled: false,
            playbackState: .stopped,
            sceneHasActiveParticles: true,
            continuousViewportInteractionActive: false
        ))
    }

    @Test("Heartbeat forces a frame after the interval even when clean")
    func heartbeatForcesFrame() {
        var gate = EditorViewportRenderGate()
        let sig = signature()
        _ = settled(&gate, sig, at: 0)

        let beforeHeartbeat = decide(&gate, sig, now: 0.5)
        #expect(!beforeHeartbeat)
        let afterHeartbeat = decide(&gate, sig,
                                    now: EditorViewportRenderGate.heartbeatInterval + 0.01)
        #expect(afterHeartbeat)
    }

    @Test("Realtime toggle reducer and codable round trip")
    func realtimeStatePlumbing() throws {
        var state = EditorState()
        #expect(!state.viewportRealtimeEnabled)
        EditorReducer.reduce(state: &state, action: .setViewportRealtime(true))
        #expect(state.viewportRealtimeEnabled)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(decoded.viewportRealtimeEnabled)
    }
}
