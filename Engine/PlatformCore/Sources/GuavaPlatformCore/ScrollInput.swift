import Foundation

/// Scroll displacement is independent of display pixel density. Precise
/// platforms report logical points; discrete wheels report line increments.
public enum ScrollUnit: String, Codable, Sendable { case points, lines, pages }

/// Precision describes the stream, not the physical hardware: a Magic Mouse
/// or a smooth-scrolling driver can produce the same packets as a trackpad.
public enum ScrollDevice: String, Codable, Sendable { case unknown, wheel, continuous }

public enum ScrollPhase: String, Codable, Sendable {
    case none, mayBegin, began, changed, stationary, ended, cancelled
}

public struct ScrollInput: Codable, Sendable, Equatable {
    public var unit: ScrollUnit = .lines
    public var device: ScrollDevice = .unknown
    public var phase: ScrollPhase = .none
    public var momentumPhase: ScrollPhase = .none
    /// Monotonic source timestamp in seconds. Zero means unavailable.
    public var timestamp: Double = 0

    public init(unit: ScrollUnit = .lines, device: ScrollDevice = .unknown,
                phase: ScrollPhase = .none, momentumPhase: ScrollPhase = .none,
                timestamp: Double = 0) {
        self.unit = unit; self.device = device; self.phase = phase
        self.momentumPhase = momentumPhase; self.timestamp = timestamp
    }

    public var isContinuation: Bool {
        momentumPhase != .none || phase == .changed || phase == .stationary
            || phase == .ended || phase == .cancelled
    }
}

public extension MouseWheelEvent {
    /// Converts units exactly once. The sign remains that of the native
    /// stream; content offsets normally subtract this displacement.
    func displacement(lineStep: Float, pageWidth: Float = 0, pageHeight: Float = 0) -> (x: Float, y: Float) {
        switch input.unit {
        case .points: (x, y)
        case .lines: (x * lineStep, y * lineStep)
        case .pages: (x * pageWidth, y * pageHeight)
        }
    }
}
