internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Window-level feedback for what the user just did. Session state only: it is
/// never persisted, and the console keeps the history of every message.
final class EditorNotifications {
    let center = ToastController(maxVisible: 3)

    nonisolated(unsafe) private static var byApplication: [ObjectIdentifier: EditorNotifications] = [:]

    /// One queue per project window.
    static func of(_ app: EditorApplication) -> EditorNotifications {
        let key = ObjectIdentifier(app)
        if let existing = byApplication[key] { return existing }
        let created = EditorNotifications()
        byApplication[key] = created
        return created
    }

    /// A stable `id` replaces the previous notice of the same kind instead of stacking.
    func post(_ title: String, id: String, tone: StatusTone = .info, duration: Double? = 2,
              message: String = "", action: ToastAction? = nil) {
        center.post(ToastNotification(title, id: id) {
            $0.tone = tone
            $0.duration = duration
            $0.message = message
            $0.actions = action.map { [$0] } ?? []
        })
    }

    /// Scene edits are refused while the game runs; say so and offer the way out.
    func postBlockedByPlayback(_ title: String, app: EditorApplication) {
        post(title, id: "playback-blocked", tone: .warning, duration: 5,
             action: ToastAction(L("Stop")) { app.applyPlaybackState(.stopped) })
    }
}

/// Anchors notifications below the title bar so they never cover run controls.
struct EditorNotificationHost: View {
    let notifications: EditorNotifications

    var body: some View {
        ThemeReader { theme in
            SurfaceReader { surface in
                var below = surface
                below.safeArea.top += EditorNotificationHost.titleBarClearance
                // Viewport overlays keep the translucent floating surface; a
                // notice must stay readable over whatever panel it covers.
                var opaque = theme
                opaque.colors.surfaceFloating = theme.colors.surfaceRaised
                return NotificationHost(notifications.center, width: 340, position: .topTrailing)
                    .surfaceEnvironment(below)
                    .theme(opaque)
            }
        }
    }

    /// Title bar height minus the toast margin, leaving an 8pt gap.
    static let titleBarClearance: Float = 32
}
