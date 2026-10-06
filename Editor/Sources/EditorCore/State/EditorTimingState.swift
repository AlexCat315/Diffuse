import Foundation
import IntentRuntime

/// Owns the editor timing state and its persistence defaults.
public struct EditorTimingState: Codable, Sendable {
    public var connected: Bool = false
    public var playbackState: PlaybackState = .stopped
    public var frameIndex: UInt64 = 0
    public var frameTimingRevision: UInt64 = 0
    public var frameStats: EditorFrameStats = .init()
    public var frameStatsHistory: [EditorFrameStatsHistorySample] = []
    public var particleDiagnosticsHistory: [EditorParticleDiagnosticsSample] = []

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case connected
        case playbackState
        case frameIndex
        case frameTimingRevision
        case frameStats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? connected
        playbackState = try container.decodeIfPresent(PlaybackState.self, forKey: .playbackState) ?? playbackState
        frameIndex = try container.decodeIfPresent(UInt64.self, forKey: .frameIndex) ?? frameIndex
        frameTimingRevision =
            try container.decodeIfPresent(UInt64.self, forKey: .frameTimingRevision) ?? frameTimingRevision
        frameStats = try container.decodeIfPresent(EditorFrameStats.self, forKey: .frameStats) ?? frameStats
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connected, forKey: .connected)
        try container.encode(playbackState, forKey: .playbackState)
        try container.encode(frameIndex, forKey: .frameIndex)
        try container.encode(frameTimingRevision, forKey: .frameTimingRevision)
        try container.encode(frameStats, forKey: .frameStats)
    }

    mutating func normalize() {
        frameStatsHistory = Array(frameStatsHistory.suffix(EditorState.maxFrameStatsHistorySamples))
        particleDiagnosticsHistory = Array(
            particleDiagnosticsHistory.suffix(EditorState.maxParticleDiagnosticsHistorySamples)
        )
    }
}
