import SceneRuntime

public enum EditorViewportFrameDrive {
    public static func wantsContinuousFrames(viewportRealtimeEnabled: Bool,
                                             playbackState: PlaybackState,
                                             sceneHasActiveParticles: Bool,
                                             continuousViewportInteractionActive: Bool) -> Bool {
        viewportRealtimeEnabled
            || playbackState == .playing
            || sceneHasActiveParticles
            || continuousViewportInteractionActive
    }
}
