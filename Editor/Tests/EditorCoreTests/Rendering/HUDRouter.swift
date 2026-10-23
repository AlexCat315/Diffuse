import Foundation
import RenderBackend

/// A test-scoped provider allows failure and enable/disable cases to share
/// one renderer without installing process-wide state.
final class HUDRouter: InGameUIProviding, @unchecked Sendable {
    var provider: (any InGameUIProviding)?
    func recordInGameUI(packet: RenderPacket, target: NativeInGameUITarget) throws -> InGameUIRecording? {
        try provider?.recordInGameUI(packet: packet, target: target)
    }
}

enum GlobalTestLock {
    private static let lock = NSRecursiveLock()
    static func locked<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try action()
    }
}
