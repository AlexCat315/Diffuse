#if os(macOS)
import AppKit
import CSDL3
import Testing
@testable import PlatformShell
import EngineKernel

@Suite("AppKit scroll decoding", .serialized)
struct AppKitScrollInputTests {
    @MainActor @Test("Native point/line units, finger phase and independent OS momentum survive decoding")
    func nativeMetadata() throws {
        for precise in [false, true] {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                         wheelCount: 2, wheel1: 12, wheel2: -7, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
            let event = try #require(NSEvent(cgEvent: cg))
            let decoded = AppKitScrollInput.decode(event, mouseX: 40, mouseY: 60)
            #expect(decoded.input.unit == (precise ? .points : .lines))
            #expect(decoded.input.phase == .ended)
            #expect(decoded.input.momentumPhase == .began)
            #expect(decoded.x == Float(event.scrollingDeltaX))
            #expect(decoded.y == Float(event.scrollingDeltaY))
            #expect(decoded.mouseX == 40 && decoded.mouseY == 60)
            #expect(decoded.input.timestamp == event.timestamp)
        }
    }

    @MainActor @Test("Zero-displacement end packets retain the end signal")
    func phaseOnly() throws {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                     wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 8)
        let event = try #require(NSEvent(cgEvent: cg))
        let decoded = AppKitScrollInput.decode(event, mouseX: 0, mouseY: 0)
        #expect(decoded.x == 0 && decoded.y == 0)
        #expect(decoded.input.phase == .cancelled)
    }

    @MainActor @Test("Synthetic AppKit markers preserve zero ends, logical units and SDL queue order")
    func nativeQueue() throws {
        // The adapter only needs the SDL event queue. Starting SDL video here
        // changes NSApplication's lifecycle for unrelated tests in this process.
        _ = NSApplication.shared
        #expect(SDL_InitSubSystem(SDL_INIT_EVENTS))
        defer { SDL_QuitSubSystem(SDL_INIT_EVENTS) }
        let adapter = try #require(AppKitScrollInput())
        defer { adapter.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let windowID: WindowID = 42
        adapter.register(windowID, window: window)
        // Synthetic NSEvent packets exercise the real AppKit local monitor
        // and SDL queue without WindowServer posting permissions or hardware.
        for (delta, phase): (Int32, NSEvent.Phase) in [(12, .began), (8, .changed), (0, .ended)] {
            NSApp.sendEvent(try WindowScrollEvent(window: window, delta: delta, phase: phase))
            if phase == .began {
                var motion = SDL_Event()
                motion.type = UInt32(GUAVA_SDL_EVENT_MOUSE_MOTION)
                motion.motion.windowID = windowID
                motion.motion.x = 123
                motion.motion.y = 45
                #expect(SDL_PushEvent(&motion))
            }
        }
        var routed: [WindowInputEvent] = []
        var queued = SDL_Event()
        while SDL_PollEvent(&queued) {
            if queued.type == adapter.eventType, let input = adapter.take(queued.user.code) {
                routed.append(input)
            } else if queued.type == UInt32(GUAVA_SDL_EVENT_MOUSE_MOTION) {
                routed.append(.init(windowID: queued.motion.windowID,
                                    event: .mouseMotion(.init(x: queued.motion.x, y: queued.motion.y, deltaX: 0, deltaY: 0))))
            }
        }
        let wheels = routed.compactMap { routed -> MouseWheelEvent? in
            guard routed.windowID == windowID, case .mouseWheel(let wheel) = routed.event else { return nil }
            return wheel
        }
        #expect(wheels.count == 3)
        #expect(wheels.map(\.input.phase) == [.began, .changed, .ended])
        #expect(wheels.allSatisfy { $0.input.unit == .points })
        #expect(wheels.map(\.y) == [12, 8, 0])
        let order = routed.compactMap { routed -> String? in
            switch routed.event {
            case .mouseWheel(let wheel): "wheel.\(wheel.input.phase.rawValue)"
            case .mouseMotion: "motion"
            default: nil
            }
        }
        #expect(order == ["wheel.began", "motion", "wheel.changed", "wheel.ended"])
    }
}
private final class WindowScrollEvent: NSEvent {
    private let nativeWindow: NSWindow
    private let number: Int
    private let source: NSEvent
    private let scrollPhase: NSEvent.Phase

    @MainActor init(window: NSWindow, delta: Int32, phase: NSEvent.Phase) throws {
        nativeWindow = window; number = window.windowNumber; scrollPhase = phase
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                     wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0))
        source = try #require(NSEvent(cgEvent: cg))
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not an archived event") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { nativeWindow }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { NSPoint(x: 50, y: 50) }
    override var timestamp: TimeInterval { source.timestamp }
    override var deltaX: CGFloat { source.deltaX }
    override var deltaY: CGFloat { source.deltaY }
    override var scrollingDeltaX: CGFloat { source.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { source.scrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var isDirectionInvertedFromDevice: Bool { false }
    override var cgEvent: CGEvent? { source.cgEvent }
}
#endif
