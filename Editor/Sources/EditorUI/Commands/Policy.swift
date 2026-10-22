internal import EditorCore

/// One command policy for menus, the palette, keyboard dispatch and native menus.
enum EditorWorkspaceCommandPolicy {
    static func allows(_ command: EditorCommand, in mode: EditorWorkspaceMode) -> Bool {
        let profile = mode.profile
        switch command {
        case .showPanel(let id), .togglePanel(let id), .maximizePanel(let id): return profile.allowsPanel(id)
        case .showSceneSettings, .newScene, .openScene, .saveScene, .duplicateSelection, .deleteSelection,
             .selectAll, .clearSelection, .invertSelection, .selectDescendants, .spawnEntity, .frameSelection,
             .toggleSelectionVisibility, .toggleSelectionLock:
            return profile.features.contains(.scene)
        case .saveDocument, .revertDocument, .closeDocument: return profile.features.contains(.documents)
        case .showAssets, .importAssets: return profile.allowsPanel("assets")
        case .buildProject, .buildAndRun: return profile.features.contains(.gameBuild)
        case .runTask: return profile.allowsPanel("tasks")
        case .setPlaybackState, .togglePlayback: return profile.features.contains(.gameplay)
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
