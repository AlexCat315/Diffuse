import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func processIsAlive(_ pid: Int) -> Bool {
    #if os(Windows)
    false
    #else
    kill(pid_t(pid), 0) == 0 || errno == EPERM
    #endif
}

/// Keeps cleanup on the owning CLI flow; signal callbacks only request cancellation.
final class RunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var signals: [DispatchSourceSignal] = []
    var isCancelled: Bool { lock.withLock { cancelled } }

    init() {
        #if !os(Windows)
        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { [weak self] in self?.lock.withLock { self?.cancelled = true } }
            source.resume(); signals.append(source)
        }
        #endif
    }
    deinit {
        for source in signals { source.cancel() }
        #if !os(Windows)
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
        #endif
    }
}
