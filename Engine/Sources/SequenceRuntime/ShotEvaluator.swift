import Foundation

public struct EvaluatedShot: Sendable, Equatable {
    public var shotID: String
    public var name: String
    public var shotFrame: Int64
    public var status: ShotStatus

    public init(shotID: String, name: String, shotFrame: Int64, status: ShotStatus) {
        self.shotID = shotID
        self.name = name
        self.shotFrame = shotFrame
        self.status = status
    }
}

public struct EvaluatedCut: Sendable, Equatable {
    public var cut: Cut
    public var progress: Double

    public init(cut: Cut, progress: Double) {
        self.cut = cut
        self.progress = progress
    }
}

public struct EvaluatedSequenceFrame: Sendable, Equatable {
    public var sequenceFrame: Int64
    public var shot: EvaluatedShot?
    public var activeClips: [ScheduledClip]
    public var activeMarkers: [Marker]
    public var activeCut: EvaluatedCut?

    public init(sequenceFrame: Int64,
                shot: EvaluatedShot?,
                activeClips: [ScheduledClip],
                activeMarkers: [Marker],
                activeCut: EvaluatedCut?) {
        self.sequenceFrame = sequenceFrame
        self.shot = shot
        self.activeClips = activeClips
        self.activeMarkers = activeMarkers
        self.activeCut = activeCut
    }
}

public enum ShotEvaluator {
    public static func evaluate(_ sequence: SequenceDocument,
                                at sequenceFrame: Int64,
                                options: SequenceEvaluationOptions = SequenceEvaluationOptions()) -> EvaluatedSequenceFrame {
        let activeShot = sequence.shot(containing: sequenceFrame)
        let evaluatedShot = activeShot.flatMap { shot -> EvaluatedShot? in
            guard let shotFrame = ClipScheduler.shotFrame(for: sequenceFrame, in: shot) else {
                return nil
            }
            return EvaluatedShot(shotID: shot.id,
                                 name: shot.name,
                                 shotFrame: shotFrame,
                                 status: shot.status)
        }

        return EvaluatedSequenceFrame(
            sequenceFrame: sequenceFrame,
            shot: evaluatedShot,
            activeClips: activeShot.map { ClipScheduler.activeClips(in: $0, at: sequenceFrame, options: options) } ?? [],
            activeMarkers: sequence.markers(at: sequenceFrame),
            activeCut: activeCut(in: sequence, at: sequenceFrame)
        )
    }

    public static func activeCut(in sequence: SequenceDocument, at sequenceFrame: Int64) -> EvaluatedCut? {
        let activeCuts = sequence.cuts.filter { cut in
            switch cut.transition {
            case .hard:
                return cut.frame == sequenceFrame
            case .dissolve, .fadeIn, .fadeOut, .wipe:
                let duration = max(1, cut.duration)
                return sequenceFrame >= cut.frame && sequenceFrame < cut.frame + duration
            }
        }
        guard let cut = activeCuts.sorted(by: { $0.frame > $1.frame }).first else {
            return nil
        }
        let progress: Double
        if cut.transition == .hard || cut.duration <= 0 {
            progress = 1.0
        } else {
            progress = min(1.0, max(0.0, Double(sequenceFrame - cut.frame) / Double(cut.duration)))
        }
        return EvaluatedCut(cut: cut, progress: progress)
    }
}