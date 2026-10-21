internal import Foundation
#if canImport(Darwin)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#endif

#if os(macOS) || os(Linux) || os(Windows)
enum ProcessPlatform {
    static func prepareInput(_ handle: FileHandle) {
        #if os(macOS)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    static func write(_ data: Data, to handle: FileHandle) throws {
        #if os(Linux)
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var original = sigset_t()
        var pending = sigset_t()
        sigpending(&pending)
        let alreadyPending = sigismember(&pending, SIGPIPE) == 1
        pthread_sigmask(SIG_BLOCK, &blocked, &original)
        defer {
            if !alreadyPending, sigismember(&original, SIGPIPE) != 1 {
                var timeout = timespec(tv_sec: 0, tv_nsec: 0)
                _ = sigtimedwait(&blocked, nil, &timeout)
            }
            pthread_sigmask(SIG_SETMASK, &original, nil)
        }
        #endif
        try handle.write(contentsOf: data)
    }

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
