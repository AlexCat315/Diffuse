import Foundation

public enum SequenceFPSRemapMode: Sendable, Equatable {
    case preserveDurationRatio
    case preserveFrameCount
}

public struct SequenceEvaluationOptions: Sendable, Equatable {
    public var soloTrackIDs: Set<String>

    public init(soloTrackIDs: Set<String> = []) {
        self.soloTrackIDs = soloTrackIDs
    }
}

public struct ScheduledClip: Sendable, Equatable {
    public var shotID: String
    public var trackID: String
    public var trackKind: TrackKind
    public var clipID: String
    public var sequenceFrame: Int64
    public var shotFrame: Int64
    public var sourceFrame: Double
    public var weight: Double

    public init(shotID: String,
                trackID: String,
                trackKind: TrackKind,
                clipID: String,
                sequenceFrame: Int64,
                shotFrame: Int64,
                sourceFrame: Double,
                weight: Double) {
        self.shotID = shotID
        self.trackID = trackID
        self.trackKind = trackKind
        self.clipID = clipID
        self.sequenceFrame = sequenceFrame
        self.shotFrame = shotFrame
        self.sourceFrame = sourceFrame
        self.weight = weight
    }
}

public enum ClipScheduler {
    public static func shotFrame(for sequenceFrame: Int64, in shot: Shot) -> Int64? {
        guard shot.range.contains(sequenceFrame) else { return nil }
        return sequenceFrame - shot.range.start + shot.sourceOffset
    }

    public static func sourceFrame(for shotFrame: Int64, clip: Clip) -> Double? {
        guard clip.enabled, clip.shotRange.contains(shotFrame), clip.timeWarp >= 0 else {
            return nil
        }
        if clip.timeWarp == 0 {
            return Double(clip.sourceOffset)
        }
        let localFrame = shotFrame - clip.shotRange.start
        return Double(clip.sourceOffset) + Double(localFrame) * clip.timeWarp
    }

    public static func clipIsValid(_ clip: Clip, within shot: Shot) -> Bool {
        guard shot.range.duration >= 0,
              shot.range.contains(FrameRange(start: shot.range.start + clip.shotRange.start,
                                             end: shot.range.start + clip.shotRange.end))
        else {
            return false
        }
        guard clip.timeWarp >= 0 else { return false }
        return clip.blendInFrames + clip.blendOutFrames <= clip.shotRange.duration
    }

    public static func activeClips(in shot: Shot,
                                   at sequenceFrame: Int64,
                                   options: SequenceEvaluationOptions = SequenceEvaluationOptions()) -> [ScheduledClip] {
        guard let shotFrame = shotFrame(for: sequenceFrame, in: shot) else {
            return []
        }
        let activeSoloIDs: Set<String>
        if options.soloTrackIDs.isEmpty {
            activeSoloIDs = Set(shot.tracks.filter(\ .solo).map(\ .id))
        } else {
            activeSoloIDs = options.soloTrackIDs
        }

        var result: [ScheduledClip] = []
        for track in shot.tracks {
            if track.mute { continue }
            if !activeSoloIDs.isEmpty && !activeSoloIDs.contains(track.id) { continue }

            for clip in track.clips where clip.enabled && clip.shotRange.contains(shotFrame) {
                guard clipIsValid(clip, within: shot),
                      let sourceFrame = sourceFrame(for: shotFrame, clip: clip)
                else {
                    continue
                }
                result.append(
                    ScheduledClip(
                        shotID: shot.id,
                        trackID: track.id,
                        trackKind: track.kind,
                        clipID: clip.id,
                        sequenceFrame: sequenceFrame,
                        shotFrame: shotFrame,
                        sourceFrame: sourceFrame,
                        weight: clip.weight * blendWeight(for: shotFrame, clip: clip)
                    )
                )
            }
        }
        return result
    }

    public static func remapFrameRange(_ range: FrameRange,
                                       from source: TimeBase,
                                       to destination: TimeBase,
                                       mode: SequenceFPSRemapMode) -> FrameRange {
        switch mode {
        case .preserveFrameCount:
            return range
        case .preserveDurationRatio:
            let ratio = Double(destination.fps) / Double(max(source.fps, 1))
            let mappedStart = Int64((Double(range.start) * ratio).rounded())
            let mappedEnd = Int64((Double(range.end) * ratio).rounded())
            return FrameRange(start: mappedStart, end: max(mappedStart, mappedEnd))
        }
    }

    private static func blendWeight(for shotFrame: Int64, clip: Clip) -> Double {
        var weight = 1.0
        let localFrame = shotFrame - clip.shotRange.start

        if clip.blendInFrames > 0 {
            let inWeight = min(1.0, max(0.0, Double(localFrame) / Double(clip.blendInFrames)))
            weight = min(weight, inWeight)
        }
        if clip.blendOutFrames > 0 {
            let remainingFrames = max(0, clip.shotRange.end - shotFrame)
            let outWeight = min(1.0,
                                max(0.0, Double(remainingFrames) / Double(clip.blendOutFrames)))
            weight = min(weight, outWeight)
        }
        return weight
    }
}