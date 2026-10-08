// NativeRHI — cross-platform explicit graphics RHI (Swift port of guava-rhi).
//
// Errors surfaced by the RHI. All failures are explicit: the Swift port never
// silently truncates input or swallows backend allocation failures.

import Foundation

public enum RHIError: Error, CustomStringConvertible, Equatable {
    case unsupportedBackend(String)
    case unsupportedFeature(String)
    case invalidArgument(String)
    case layoutMismatch(String)
    case outOfMemory
    case swapchainAcquireFailed(String)
    case submitFailed(String)
    case presentFailed(String)
    case deviceLost
    case frameNotActive

    public var description: String {
        switch self {
        case .unsupportedBackend(let detail): return "RHI: unsupported backend — \(detail)"
        case .unsupportedFeature(let detail): return "RHI: unsupported feature — \(detail)"
        case .invalidArgument(let detail): return "RHI: invalid argument — \(detail)"
        case .layoutMismatch(let detail): return "RHI: layout mismatch — \(detail)"
        case .outOfMemory: return "RHI: out of memory"
        case .swapchainAcquireFailed(let detail): return "RHI: swapchain acquire failed — \(detail)"
        case .submitFailed(let detail): return "RHI: submit failed — \(detail)"
        case .presentFailed(let detail): return "RHI: present failed — \(detail)"
        case .deviceLost: return "RHI: device lost"
        case .frameNotActive: return "RHI: no frame is active (call beginFrame first)"
        }
    }
}

@inlinable
func rhiRequire(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw RHIError.invalidArgument(message()) }
}
