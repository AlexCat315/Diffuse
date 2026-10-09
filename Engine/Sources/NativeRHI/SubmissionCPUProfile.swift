import Foundation

/// Optional synchronous CPU instrumentation for one or more submissions.
/// Use a fresh instance per sample; read it after `Device.submit` returns.
/// These durations exclude GPU completion and frame-slot waits.
/// Completed phases accumulate; a phase that throws may have no sample.
public final class SubmissionCPUProfile {
    public private(set) var validationNanoseconds: UInt64 = 0
    public private(set) var planningNanoseconds: UInt64 = 0
    public private(set) var encodingNanoseconds: UInt64 = 0
    public private(set) var queueSubmitNanoseconds: UInt64 = 0

    public init() {}

    enum Phase { case validation, planning, encoding, queueSubmit }

    func begin() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func end(_ phase: Phase, since start: UInt64?) {
        guard let start else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        switch phase {
        case .validation: validationNanoseconds += elapsed
        case .planning: planningNanoseconds += elapsed
        case .encoding: encodingNanoseconds += elapsed
        case .queueSubmit: queueSubmitNanoseconds += elapsed
        }
    }
}
