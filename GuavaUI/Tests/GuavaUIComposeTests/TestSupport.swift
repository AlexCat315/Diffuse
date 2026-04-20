import Foundation

/// All compose tests that mutate the process-wide holders
/// (`InteractionRegistryHolder`, `FocusChainHolder`, `TextEnvironmentHolder`)
/// must run under this lock. Swift Testing parallelises across suites, and
/// `.serialized` only orders cases inside a single suite.
enum GlobalTestLock {
    nonisolated(unsafe) static let lock = NSLock()

    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

protocol GuavaUIComposeSerializedSuite {}
