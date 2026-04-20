import Foundation

/// Identifier for a window owned by a `PlatformHost`.
///
/// Phase 6 ships single-window only (always `.main`); the typealias exists so
/// every input/event API can carry a window discriminator without a later
/// breaking change. See `docs/guava-ui-blueprint.md §9.4`.
public typealias WindowID = UInt32

public extension WindowID {
    static let main: WindowID = 0
}
