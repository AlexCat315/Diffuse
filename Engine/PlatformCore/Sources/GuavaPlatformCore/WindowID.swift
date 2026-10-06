import Foundation

/// Identifier for a native window managed by the platform shell.
///
/// `.main` is kept as the compatibility default for legacy single-window
/// call sites and tests.
public typealias WindowID = UInt32

public extension WindowID {
    static let main: WindowID = 0
}