import Foundation

/// Controls which capability maturity stages are accessible in the running process.
///
/// In production builds, `activePhase` is `.stable`. In internal/opt-in builds
/// it can be elevated to `.beta` or `.experimental` to expose in-progress work.
public struct ReleasePhaseGate: Sendable {
    /// The minimum maturity that may be used. Capabilities whose `releasePhase`
    /// is less mature than `activePhase` are denied; `.disabled` is always denied.
    public var activePhase: CapabilityReleasePhase

    public init(activePhase: CapabilityReleasePhase = .stable) {
        self.activePhase = activePhase
    }

    // MARK: - Query

    /// Whether `descriptor`'s release phase is allowed under the current gate.
    ///
    /// `activePhase` is the minimum maturity the gate accepts. A capability with
    /// `releasePhase = .beta` is blocked when `activePhase = .stable`, but passes
    /// when `activePhase = .beta` or `.experimental`.
    public func isAllowed(_ descriptor: CapabilityDescriptor) -> Bool {
        descriptor.releasePhase != .disabled && descriptor.releasePhase >= activePhase
    }

    /// Human-readable denial reason, or `nil` if the descriptor passes the gate.
    public func deniedReason(for descriptor: CapabilityDescriptor) -> String? {
        guard !isAllowed(descriptor) else { return nil }
        switch descriptor.releasePhase {
        case .disabled:
            return "'\(descriptor.verb)' is permanently disabled"
        case .experimental:
            return "'\(descriptor.verb)' is experimental; enable the experimental gate to use it"
        case .beta:
            return "'\(descriptor.verb)' is in beta; enable the beta gate to use it"
        case .stable:
            return nil
        }
    }
}
