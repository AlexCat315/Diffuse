import SceneRuntime

public enum EditorViewportFrameDrive {
    public static func wantsContinuousFrames(viewportRealtimeEnabled: Bool,
                                             playbackState: PlaybackState,
                                             continuousViewportInteractionActive: Bool) -> Bool {
        viewportRealtimeEnabled
            || playbackState == .playing
            || continuousViewportInteractionActive
    }
}
