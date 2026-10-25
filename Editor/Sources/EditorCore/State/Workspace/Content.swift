import Foundation

/// What the center of the window shows. The panels around it, the inspector's
/// sections, the commands and the assistant's tools follow it.
public enum EditorContent: String, Codable, Sendable, Hashable, CaseIterable {
    case scene
    case files
    case timeline

    public var title: String {
        switch self {
        case .scene: "Scene"
        case .files: "Files"
        case .timeline: "Timeline"
        }
    }

    public var profile: EditorWorkspaceProfile { .profile(for: self) }
}
