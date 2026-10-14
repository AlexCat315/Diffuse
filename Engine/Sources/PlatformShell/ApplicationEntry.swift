import CSDL3
import Foundation

/// Installs the platform application lifecycle before constructing windows.
@MainActor
public enum PlatformApplication {
    public static func run<Result>(_ body: @escaping @MainActor () throws -> Result) throws {
        #if os(iOS)
        let invocation = ApplicationInvocation { try body() }
        let pointer = Unmanaged.passUnretained(invocation).toOpaque()
        let status = guava_sdl_run_app({ pointer in
            MainActor.assumeIsolated {
                let invocation = Unmanaged<ApplicationInvocation>.fromOpaque(pointer!).takeUnretainedValue()
                do { invocation.runtime = try invocation.body(); return 0 }
                catch { invocation.error = error; return 1 }
            }
        }, pointer)
        if let error = invocation.error { throw error }
        guard status == 0 else { throw ShellError.initializationFailed("SDL application entry failed: \(status)") }
        #else
        _ = try body()
        #endif
    }
}

#if os(iOS)
@MainActor
private final class ApplicationInvocation {
    let body: @MainActor () throws -> Any
    var error: (any Error)?
    var runtime: Any?
    init(_ body: @escaping @MainActor () throws -> Any) { self.body = body }
}
#endif
