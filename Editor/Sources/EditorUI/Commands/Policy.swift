internal import EditorCore

/// One command policy for menus, the palette, keyboard dispatch and native menus.
/// Scene editing follows the scene; file commands follow files. Panels, playback
/// and builds stay available whatever the window centers on.
enum EditorWorkspaceCommandPolicy {
    static func allows(_ command: EditorCommand, in content: EditorContent) -> Bool {
        let features = content.profile.features
        switch command {
        case .showSceneSettings, .newScene, .openScene, .saveScene, .duplicateSelection, .deleteSelection,
             .selectAll, .clearSelection, .invertSelection, .selectDescendants, .spawnEntity, .createGeometry, .frameSelection,
             .toggleSelectionVisibility, .toggleSelectionLock:
            return features.contains(.scene)
        case .saveDocument, .revertDocument, .closeDocument: return features.contains(.documents)
        default: return true
        }
    }
}

enum EditorPlaybackCommandPolicy {
    static func canTransition(from current: PlaybackState, to next: PlaybackState) -> Bool {
        current.canTransition(to: next)
    }

    /// Play from stopped or paused; pause while playing.
    static func toggleTarget(from current: PlaybackState) -> PlaybackState {
        current == .playing ? .paused : .playing
    }
}

enum EditorSceneAuthoringPolicy {
    static func canEditScene(during playbackState: PlaybackState) -> Bool {
        playbackState == .stopped
    }
}
