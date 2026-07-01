import EditorCore
import Foundation
import RenderBackend
import Testing

@Suite("EditorViewportResolution")
struct EditorViewportResolutionTests {
    @Test("Native scale passes the presentation size through")
    func nativeScaleIsIdentity() {
        let size = EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 2800, height: 1600),
            renderScalePercent: 100,
            interactionDownscaleActive: false
        )
        #expect(size == RenderDrawableSize(width: 2800, height: 1600))
    }

    @Test("Render scale percent shrinks and supersamples with rounding")
    func percentScales() {
        #expect(EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 2801, height: 1601),
            renderScalePercent: 50,
            interactionDownscaleActive: false
        ) == RenderDrawableSize(width: 1401, height: 801))

        #expect(EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 1400, height: 800),
            renderScalePercent: 200,
            interactionDownscaleActive: false
        ) == RenderDrawableSize(width: 2800, height: 1600))
    }

    @Test("Interaction downscale stacks an extra halving on top of the scale")
    func interactionFactorStacks() {
        let size = EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 2800, height: 1600),
            renderScalePercent: 100,
            interactionDownscaleActive: true
        )
        #expect(size == RenderDrawableSize(width: 1400, height: 800))

        let scaled = EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 2800, height: 1600),
            renderScalePercent: 50,
            interactionDownscaleActive: true
        )
        #expect(scaled == RenderDrawableSize(width: 700, height: 400))
    }

    @Test("Effective size never collapses below one pixel and sanitizes the percent")
    func clampsAndSanitizes() {
        #expect(EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 1, height: 1),
            renderScalePercent: 25,
            interactionDownscaleActive: true
        ) == RenderDrawableSize(width: 1, height: 1))

        // Out-of-range percents clamp to the sanitized bounds (25–200).
        #expect(EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 1000, height: 1000),
            renderScalePercent: 5,
            interactionDownscaleActive: false
        ) == RenderDrawableSize(width: 250, height: 250))
        #expect(EditorViewportResolution.effectiveSize(
            presentation: RenderDrawableSize(width: 1000, height: 1000),
            renderScalePercent: 9999,
            interactionDownscaleActive: false
        ) == RenderDrawableSize(width: 2000, height: 2000))
    }

    @Test("Reducer sanitizes the render scale percent and toggles downscale")
    func reducerHandlesRenderScaleActions() {
        var state = EditorState()
        #expect(state.viewportRenderScalePercent == 100)
        #expect(!state.viewportInteractionDownscaleEnabled)

        EditorReducer.reduce(state: &state, action: .setViewportRenderScalePercent(75))
        #expect(state.viewportRenderScalePercent == 75)

        EditorReducer.reduce(state: &state, action: .setViewportRenderScalePercent(9999))
        #expect(state.viewportRenderScalePercent == 200)

        EditorReducer.reduce(state: &state, action: .setViewportRenderScalePercent(1))
        #expect(state.viewportRenderScalePercent == 25)

        EditorReducer.reduce(state: &state, action: .setViewportInteractionDownscale(true))
        #expect(state.viewportInteractionDownscaleEnabled)
    }

    @Test("Render scale settings survive a state codable round trip")
    func renderScaleSettingsRoundTrip() throws {
        var state = EditorState()
        EditorReducer.reduce(state: &state, action: .setViewportRenderScalePercent(50))
        EditorReducer.reduce(state: &state, action: .setViewportInteractionDownscale(true))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)

        #expect(decoded.viewportRenderScalePercent == 50)
        #expect(decoded.viewportInteractionDownscaleEnabled)
    }

    @Test("Camera and gizmo drags count as continuous scene interaction, clicks do not")
    func continuousInteractionClassification() {
        let controller = EditorViewportInputController.shared
        defer { controller.reset() }

        controller.begin(.camera(.orbit, button: .left), at: (0, 0), modifiers: [])
        #expect(controller.isContinuousSceneInteractionActive)
        controller.pressedScancodes = [26]
        #expect(!controller.hasFreelookMovementInput)

        controller.begin(.gizmo(button: .left), at: (0, 0), modifiers: [])
        #expect(controller.isContinuousSceneInteractionActive)

        controller.begin(.camera(.freelook, button: .right), at: (0, 0), modifiers: [])
        #expect(controller.isContinuousSceneInteractionActive)
        #expect(controller.hasFreelookMovementInput)
        controller.pressedScancodes = [44]
        #expect(!controller.hasFreelookMovementInput)

        controller.begin(.pendingClick(button: .left), at: (0, 0), modifiers: [])
        #expect(!controller.isContinuousSceneInteractionActive)

        controller.begin(.marquee(button: .left), at: (0, 0), modifiers: [])
        #expect(!controller.isContinuousSceneInteractionActive)

        controller.endPointerSession()
        #expect(!controller.isContinuousSceneInteractionActive)
    }
}
