import Foundation

extension SequenceDocument {
    /// Returns a new SequenceDocument with all frame ranges remapped from `sourceFPS` to `destinationFPS`.
    /// Does not mutate the receiver; the caller must replace the document and create a new revision.
    public func remapping(from sourceFPS: Int,
                          to destinationFPS: Int,
                          mode: SequenceFPSRemapMode) -> SequenceDocument {
        let source = TimeBase(fps: sourceFPS)
        let destination = TimeBase(fps: destinationFPS)

        func remap(_ range: FrameRange) -> FrameRange {
            ClipScheduler.remapFrameRange(range, from: source, to: destination, mode: mode)
        }

        func remapBinding(_ b: Binding) -> Binding { b }

        func remapClip(_ clip: Clip) -> Clip {
            var c = clip
            c.shotRange = remap(clip.shotRange)
            c.blendInFrames = remapFrameCount(clip.blendInFrames, source: sourceFPS, destination: destinationFPS, mode: mode)
            c.blendOutFrames = remapFrameCount(clip.blendOutFrames, source: sourceFPS, destination: destinationFPS, mode: mode)
            c.bindings = clip.bindings.map(remapBinding)
            return c
        }

        func remapTrack(_ track: Track) -> Track {
            var t = track
            t.clips = track.clips.map(remapClip)
            return t
        }

        func remapOverride(_ o: ShotOverride) -> ShotOverride {
            var ov = o
            ov.blendInFrames = remapFrameCount(o.blendInFrames, source: sourceFPS, destination: destinationFPS, mode: mode)
            ov.blendOutFrames = remapFrameCount(o.blendOutFrames, source: sourceFPS, destination: destinationFPS, mode: mode)
            return ov
        }

        func remapShot(_ shot: Shot) -> Shot {
            var s = shot
            s.range = remap(shot.range)
            s.overrides = shot.overrides.map(remapOverride)
            s.tracks = shot.tracks.map(remapTrack)
            return s
        }

        func remapCut(_ cut: Cut) -> Cut {
            var c = cut
            c.frame = remapFrame(cut.frame, source: sourceFPS, destination: destinationFPS, mode: mode)
            c.duration = remapFrameCount(cut.duration, source: sourceFPS, destination: destinationFPS, mode: mode)
            return c
        }

        func remapMarker(_ marker: Marker) -> Marker {
            var m = marker
            m.frame = remapFrame(marker.frame, source: sourceFPS, destination: destinationFPS, mode: mode)
            return m
        }

        var doc = self
        doc.timeBase = TimeBase(fps: destinationFPS,
                                dropFrame: timeBase.dropFrame,
                                startTimecode: timeBase.startTimecode)
        doc.frameRange = remap(frameRange)
        doc.shots = shots.map(remapShot)
        doc.cuts = cuts.map(remapCut)
        doc.markers = markers.map(remapMarker)
        return doc
    }

    // MARK: - Private helpers

    private func remapFrame(_ frame: Int64,
                            source: Int,
                            destination: Int,
                            mode: SequenceFPSRemapMode) -> Int64 {
        switch mode {
        case .preserveFrameCount:
            return frame
        case .preserveDurationRatio:
            let ratio = Double(destination) / Double(max(source, 1))
            return Int64((Double(frame) * ratio).rounded())
        }
    }

    private func remapFrameCount(_ count: Int64,
                                 source: Int,
                                 destination: Int,
                                 mode: SequenceFPSRemapMode) -> Int64 {
        switch mode {
        case .preserveFrameCount:
            return count
        case .preserveDurationRatio:
            let ratio = Double(destination) / Double(max(source, 1))
            return Int64((Double(count) * ratio).rounded())
        }
    }
}
