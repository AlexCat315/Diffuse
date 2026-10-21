@testable import EditorUI
import GuavaUIRuntime
import Testing

@Suite("Editor display cadence")
struct FrameCadenceTests {
    @Test("Playback and realtime previews follow display refresh, then return to idle")
    func displayAndIdle() {
        var cadence = EditorFrameCadence()
        #expect(cadence.update(continuous: false, vsyncEnabled: true) == .eventDriven)
        #expect(cadence.update(continuous: true, vsyncEnabled: true) == .displayRefresh)
        for _ in 0..<60 {
            #expect(cadence.update(continuous: true, vsyncEnabled: true) == nil)
        }
        #expect(cadence.update(continuous: false, vsyncEnabled: true) == .eventDriven)
        #expect(cadence.update(continuous: false, vsyncEnabled: true) == nil)
    }

    @Test("Explicitly disabling VSync releases the native cadence cap")
    func uncappedSelection() {
        var cadence = EditorFrameCadence()
        #expect(cadence.update(continuous: true, vsyncEnabled: true) == .displayRefresh)
        #expect(cadence.update(continuous: true, vsyncEnabled: false) == .eventDriven)
        #expect(cadence.update(continuous: true, vsyncEnabled: false) == nil)
        #expect(cadence.update(continuous: true, vsyncEnabled: true) == .displayRefresh)
    }
}
