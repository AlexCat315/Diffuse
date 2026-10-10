import Foundation

/// Optional synchronous CPU instrumentation for one or more submissions.
/// Use a fresh instance per sample; read it after `Device.submit` returns.
/// These durations exclude GPU completion and frame-slot waits.
/// Completed phases accumulate; a phase that throws may have no sample.
///
/// The encoding sub-phases stay zero unless the profile is created with
/// `recordsEncodingDetail`, so ordinary sampling keeps its original clocks.
public final class SubmissionCPUProfile {
    public private(set) var validationNanoseconds: UInt64 = 0
    public private(set) var planningNanoseconds: UInt64 = 0
    public private(set) var encodingNanoseconds: UInt64 = 0
    public private(set) var queueSubmitNanoseconds: UInt64 = 0

    /// Attachment validation and native pass-descriptor construction.
    public private(set) var passSetupNanoseconds: UInt64 = 0
    /// Creating native command encoders.
    public private(set) var encoderCreationNanoseconds: UInt64 = 0
    /// Replaying recorded commands into native encoders.
    public private(set) var commandReplayNanoseconds: UInt64 = 0
    /// Applying binding sets inside `commandReplay`.
    public private(set) var bindingApplyNanoseconds: UInt64 = 0

    public let recordsEncodingDetail: Bool

    public init(recordsEncodingDetail: Bool = false) {
        self.recordsEncodingDetail = recordsEncodingDetail
    }

    enum Phase { case validation, planning, encoding, queueSubmit, passSetup, encoderCreation, commandReplay, bindingApply }

    func begin() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func end(_ phase: Phase, since start: UInt64?) {
        guard let start else { return }
        end(phase, elapsed: DispatchTime.now().uptimeNanoseconds - start)
    }

    /// Detail clocks are opt-in: reads zero when detail recording is off.
    func beginDetail(_ phase: Phase) -> UInt64 {
        guard recordsEncodingDetail else { return 0 }
        return DispatchTime.now().uptimeNanoseconds
    }

    func endDetail(_ phase: Phase, since start: UInt64) {
        guard recordsEncodingDetail, start != 0 else { return }
        end(phase, elapsed: DispatchTime.now().uptimeNanoseconds - start)
    }

    private func end(_ phase: Phase, elapsed: UInt64) {
        switch phase {
        case .validation: validationNanoseconds += elapsed
        case .planning: planningNanoseconds += elapsed
        case .encoding: encodingNanoseconds += elapsed
        case .queueSubmit: queueSubmitNanoseconds += elapsed
        case .passSetup: passSetupNanoseconds += elapsed
        case .encoderCreation: encoderCreationNanoseconds += elapsed
        case .commandReplay: commandReplayNanoseconds += elapsed
        case .bindingApply: bindingApplyNanoseconds += elapsed
        }
    }
}
