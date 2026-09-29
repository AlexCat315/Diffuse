import Foundation

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
public final class SwiftScriptLoader {

    // MARK: - Platform handle

    #if canImport(Darwin) || canImport(Glibc)
    private typealias LibraryHandle = UnsafeMutableRawPointer
    #elseif os(Windows)
    private typealias LibraryHandle = UnsafeMutableRawPointer // HMODULE
    #endif

    private final class LoadedLibrary: @unchecked Sendable {
        let handle: LibraryHandle

        init(handle: LibraryHandle) {
            self.handle = handle
        }

        deinit {
            SwiftScriptLoader.closeLibrary(handle)
        }
    }

    private var loadedLibraries: [String: LoadedLibrary] = [:]

    public init() {}

    // MARK: - Loading

    /// Loads a dynamic library and returns a factory that creates an isolated
    /// `Script` instance each time it is called.
    public func loadFactory(scriptID: String,
                            libraryPath: String) throws -> @Sendable () -> Script {
        unload(scriptID: scriptID)

        let handle = try openLibrary(path: libraryPath)

        guard let symbol = lookupSymbol(handle: handle, name: "guavaCreateScript") else {
            Self.closeLibrary(handle)
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

    /// Unloads a previously loaded script library by its ID.
    public func unload(scriptID: String) {
        loadedLibraries.removeValue(forKey: scriptID)
    }

    /// Unloads every loaded library.
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
        let wide = path.withCString(encodedAs: UTF16.self) { $0 }
        let module = LoadLibraryW(wide)
        guard let module else {
            throw ScriptLoadError.dlopenFailed("LoadLibraryW failed")
        }
        return UnsafeMutableRawPointer(module)
        #else
        throw ScriptLoadError.unsupportedPlatform
        #endif
    }

    private func lookupSymbol(handle: LibraryHandle, name: String) -> UnsafeMutableRawPointer? {
        #if canImport(Darwin) || canImport(Glibc)
        return name.withCString { dlsym(handle, $0) }
        #elseif os(Windows)
        return name.withCString { GetProcAddress(handle, $0) }
        #else
        return nil
        #endif
    }

    private static func closeLibrary(_ handle: LibraryHandle) {
        #if canImport(Darwin) || canImport(Glibc)
        dlclose(handle)
        #elseif os(Windows)
        FreeLibrary(handle)
        #endif
    }
}

public enum ScriptLoadError: Error, Equatable {
    case dlopenFailed(String)
    case symbolNotFound(String)
    case unsupportedPlatform
}
