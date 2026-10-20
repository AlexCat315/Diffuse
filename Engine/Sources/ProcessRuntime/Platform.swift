internal import Foundation
#if canImport(Darwin)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#endif

#if os(macOS) || os(Linux) || os(Windows)
enum ProcessPlatform {
    static func isolate(_ pid: Int32) {
        #if os(macOS) || os(Linux)
        // Foundation may already create a process group. Never target the
        // editor's group if the child has crossed exec before setpgid.
        _ = setpgid(pid, pid)
        #endif
    }
    static func terminate(_ process: Process, force: Bool) {
        guard process.isRunning else { return }
        #if os(macOS) || os(Linux)
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        _ = kill(target, force ? SIGKILL : SIGTERM)
        #else
        process.terminate()
        #endif
    }
}
#endif
