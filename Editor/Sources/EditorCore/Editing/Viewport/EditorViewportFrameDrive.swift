import SceneRuntime

public enum EditorViewportFrameDrive {
    public static func wantsContinuousFrames(viewportRealtimeEnabled: Bool,
                                             playbackState: PlaybackState,
                                             continuousViewportInteractionActive: Bool,
                                             isPresentationActive: Bool = true) -> Bool {
        isPresentationActive && (viewportRealtimeEnabled
            || playbackState == .playing
            || continuousViewportInteractionActive)
    }
}
