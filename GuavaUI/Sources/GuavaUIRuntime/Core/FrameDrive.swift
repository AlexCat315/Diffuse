import Foundation

/// Cadence and transient clocks belong to one host, independently of content.
final class HostFrameDrive {
    var mode = PlatformFrameRateMode.eventDriven
    var clock = HostFrameClock(now: 0)
    #if os(iOS)
    var driver: IOSFrameDriver?
    #endif
}

final class HostFrameClock {
    var lastLoopTime: Double
    var lastFramePreparationTime: Double?
    var lastAnimationTickTime: Double
    var animationsPreviouslyActive = false
    var fallbackDeadline = FrameDeadline()
    var reportedFallback = false
    init(now: Double) { lastLoopTime = now; lastAnimationTickTime = now }
}
