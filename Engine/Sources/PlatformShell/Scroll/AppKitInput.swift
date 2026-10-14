#if os(macOS)
import AppKit
private import CSDL3
import EngineKernel

/// SDL discards precise units, phase-only packets and momentum phase. Observe
/// AppKit, then enqueue markers in SDL's ordered queue. The shell skips SDL's
/// duplicate wheel packets for registered windows.
@MainActor
final class AppKitScrollInput {
    let eventType: UInt32
    private var monitor: Any?
    private var windows: [WindowID: NSWindow] = [:]
    private var pending: [Int32: WindowInputEvent] = [:]
    private var serial: Int32 = 0

    init?() {
        eventType = SDL_RegisterEvents(1)
        guard eventType != UInt32.max else { return nil }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.enqueue(event)
            return event
        }
        guard monitor != nil else { return nil }
    }

    func register(_ id: WindowID, window: NSWindow) { windows[id] = window }
    func unregister(_ id: WindowID) {
        windows[id] = nil
        pending = pending.filter { $0.value.windowID != id }
    }
    func owns(_ id: WindowID) -> Bool { windows[id] != nil }
    func take(_ code: Int32) -> WindowInputEvent? { pending.removeValue(forKey: code) }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; windows.removeAll(); pending.removeAll()
    }

    private func enqueue(_ event: NSEvent) {
        guard let (id, window) = windows.first(where: { $0.value === event.window || $0.value.windowNumber == event.windowNumber }),
              let view = window.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let wheel = Self.decode(event, mouseX: Float(point.x),
                                mouseY: Float(view.isFlipped ? point.y : view.bounds.height - point.y))
        serial &+= 1
        pending[serial] = WindowInputEvent(windowID: id, event: .mouseWheel(wheel))
        var marker = SDL_Event()
        marker.type = eventType
        marker.user.windowID = id
        marker.user.code = serial
        if !SDL_PushEvent(&marker) { pending[serial] = nil }
    }

    static func decode(_ event: NSEvent, mouseX: Float, mouseY: Float) -> MouseWheelEvent {
        MouseWheelEvent(x: Float(event.scrollingDeltaX), y: Float(event.scrollingDeltaY),
                        mouseX: mouseX, mouseY: mouseY,
                        input: .init(unit: event.hasPreciseScrollingDeltas ? .points : .lines,
                                     device: event.hasPreciseScrollingDeltas ? .continuous : .wheel,
                                     phase: phase(event.phase), momentumPhase: phase(event.momentumPhase),
                                     timestamp: event.timestamp))
    }

    private static func phase(_ value: NSEvent.Phase) -> ScrollPhase {
        if value.contains(.cancelled) { return .cancelled }
        if value.contains(.ended) { return .ended }
        if value.contains(.began) { return .began }
        if value.contains(.changed) { return .changed }
        if value.contains(.stationary) { return .stationary }
        if value.contains(.mayBegin) { return .mayBegin }
        return .none
    }
}
#endif
