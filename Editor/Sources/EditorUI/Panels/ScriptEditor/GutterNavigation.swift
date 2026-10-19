import Foundation

/// An external navigation request takes precedence over an older gutter action.
struct ScriptGutterNavigation {
    var externalID: UUID?
    var characterIndex: Int?
    let id = UUID()
}
