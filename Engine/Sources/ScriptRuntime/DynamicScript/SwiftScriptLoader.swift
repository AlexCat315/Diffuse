import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// Loads compiled Swift script dynamic libraries (`.dylib`/`.so`/`.dll`)
/// into the engine process and extracts the `Script` they produce.
///
/// The compiler-generated shim exports a single C function:
///
/// ```
/// @_cdecl("guavaCreateScript")
/// public func guavaCreateScript(_ out: UnsafeMutablePointer<Script>)
/// ```
///
/// The factory writes a fully configured `Script` value into the out-parameter.
/// Returning the `Script` by value is avoided because the C calling convention
/// does not guarantee Swift struct layout across a dylib boundary on all
/// platforms; writing through a pointer is portable.
public final class SwiftScriptLoader: @unchecked Sendable {

    // MARK: - Platform handle

    #if canImport(Darwin) || canImport(Glibc)
    private typealias LibraryHandle = UnsafeMutableRawPointer
    #elseif os(Windows)
    private typealias LibraryHandle = HMODULE
    #endif

    private final class LoadedLibrary: @unchecked Sendable {
        let handle: LibraryHandle

        init(handle: LibraryHandle) {
            self.handle = handle
        }

        // Swift registers metadata and protocol conformances process-wide.
        // Unmapping an image leaves those runtime records pointing into freed
        // memory, even after all Script instances have been released. Keep the
        // OS loader's reference for the lifetime of this process.
    }

    private var loadedLibraries: [String: LoadedLibrary] = [:]

    public init() {}

    // MARK: - Loading

    /// Loads a dynamic library and returns a factory that creates an isolated
    /// `Script` instance each time it is called.
    public func loadFactory(scriptID: String,
                            libraryPath: String) throws -> @Sendable () -> Script {
        // Keep the current generation mapped until the replacement has been
        // opened and validated. A failed dlopen/dlsym must never take the last
        // known-good script offline.
        let handle = try openLibrary(path: libraryPath)

        guard let symbol = lookupSymbol(handle: handle, name: "guavaCreateScript") else {
            throw ScriptLoadError.symbolNotFound("guavaCreateScript")
        }

        // The factory writes a Script value through an out-pointer.
        // We use UnsafeMutableRawPointer because @convention(c) cannot
        // reference UnsafeMutablePointer<Script> (Script is not C-representable).
        typealias CreateScriptFn = @convention(c) (UnsafeMutableRawPointer) -> Void
        let createScript = unsafeBitCast(symbol, to: CreateScriptFn.self)
        let library = LoadedLibrary(handle: handle)
        loadedLibraries[scriptID] = library

        return { [library] in
            var script = Script()
            withUnsafeMutablePointer(to: &script) { ptr in
                createScript(UnsafeMutableRawPointer(ptr))
            }
            return script.retaining(library)
        }
    }

    /// Removes the current generation by ID. Its Swift image stays mapped
    /// because the runtime can still consult its metadata.
    public func unload(scriptID: String) {
        loadedLibraries.removeValue(forKey: scriptID)
    }

    /// Removes every current generation while preserving registered Swift images.
    public func unloadAll() {
        loadedLibraries.removeAll()
    }

    deinit {
        unloadAll()
    }

    // MARK: - Platform abstraction

    private func openLibrary(path: String) throws -> LibraryHandle {
        #if canImport(Darwin) || canImport(Glibc)
        guard let handle = dlopen(path, RTLD_NOW) else {
            let msg = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw ScriptLoadError.dlopenFailed(msg)
        }
        return handle
        #elseif os(Windows)
        let module = path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let module else {
            throw ScriptLoadError.dlopenFailed("LoadLibraryW failed")
        }
        return module
        #else
        throw ScriptLoadError.unsupportedPlatform
        #endif
    }

    private func lookupSymbol(handle: LibraryHandle, name: String) -> UnsafeMutableRawPointer? {
        #if canImport(Darwin) || canImport(Glibc)
        return name.withCString { dlsym(handle, $0) }
        #elseif os(Windows)
        return name.withCString {
            guard let function = GetProcAddress(handle, $0) else { return nil }
            return unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
        }
        #else
        return nil
        #endif
    }

}

public enum ScriptLoadError: Error, Equatable {
    case dlopenFailed(String)
    case symbolNotFound(String)
    case unsupportedPlatform
}
