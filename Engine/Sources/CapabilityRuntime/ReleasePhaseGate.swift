import Foundation

public enum ReleasePhase: String, Sendable, Equatable, Codable {
    case prealpha
    case alpha
    case beta
    case rc
    case ship
}

public enum ReleaseGateDecision: String, Sendable, Equatable, Codable {
    case allow
    case warn
    case deny
}

public struct ReleasePhaseGate: Sendable, Equatable, Codable {
    public var prealpha: ReleaseGateDecision
    public var alpha: ReleaseGateDecision
    public var beta: ReleaseGateDecision
    public var rc: ReleaseGateDecision
    public var ship: ReleaseGateDecision
    public var hotfixException: Bool

    public init(prealpha: ReleaseGateDecision = .allow,
                alpha: ReleaseGateDecision = .allow,
                beta: ReleaseGateDecision = .allow,
                rc: ReleaseGateDecision = .allow,
                ship: ReleaseGateDecision = .allow,
                hotfixException: Bool = false) {
        self.prealpha = prealpha
        self.alpha = alpha
        self.beta = beta
        self.rc = rc
        self.ship = ship
        self.hotfixException = hotfixException
    }

    public func decision(for phase: ReleasePhase, isHotfix: Bool = false) -> ReleaseGateDecision {
        if phase == .ship, isHotfix, hotfixException {
            return .allow
        }
        switch phase {
        case .prealpha:
            return prealpha
        case .alpha:
            return alpha
        case .beta:
            return beta
        case .rc:
            return rc
        case .ship:
            return ship
        }
    }
}