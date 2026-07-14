import Foundation
import CapabilityRuntime
import IntentRuntime
import PluginRuntime

let runtime: any WASIComponentRuntime = (try? WasmtimeCLIComponentRuntime())
    ?? FailClosedWASIComponentRuntime()
let capabilityRegistry = CapabilityRegistry.aiDefault
let loader = PluginPackageLoader(registry: capabilityRegistry)
let limits = PluginResourceLimits.secureDefault
let stagingRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("GuavaPluginHost-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: stagingRoot,
                                         withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])

struct LoadedPlugin {
    var source: ValidatedPluginPackage
    var executionCopy: ValidatedPluginPackage
}

enum PluginHostStagingError: Error {
    case packageChangedDuringStaging
    case invalidReadResult
}

var loadedPackages: [String: LoadedPlugin] = [:]

func packagesMatch(_ lhs: ValidatedPluginPackage,
                   _ rhs: ValidatedPluginPackage) -> Bool {
    lhs.rootURL == rhs.rootURL
        && lhs.manifest == rhs.manifest
        && lhs.witContract == rhs.witContract
        && lhs.componentHash == rhs.componentHash
        && lhs.witHash == rhs.witHash
}

/// Execute only a host-owned copy. Re-hashing the copy closes the window where
/// an untrusted local package could replace component.wasm after validation but
/// before Wasmtime opens it.
func stagedExecutionCopy(of package: ValidatedPluginPackage) throws -> ValidatedPluginPackage {
    let destination = stagingRoot
        .appendingPathComponent("\(package.manifest.id)-\(UUID().uuidString).guavaplugin",
                               isDirectory: true)
    try FileManager.default.createDirectory(at: destination,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    do {
        for name in ["plugin.json", "component.wasm", "capabilities.wit"] {
            try FileManager.default.copyItem(at: package.rootURL.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }
        let copy = try loader.load(at: destination)
        guard copy.manifest == package.manifest,
              copy.witContract == package.witContract,
              copy.componentHash == package.componentHash,
              copy.witHash == package.witHash else {
            throw PluginHostStagingError.packageChangedDuringStaging
        }
        return copy
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}

func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var result = Data()
    while result.count < count {
        let chunk = handle.readData(ofLength: count - result.count)
        if chunk.isEmpty { return nil }
        result.append(chunk)
    }
    return result
}

func readRequest() throws -> PluginHostRequest? {
    guard let header = readExactly(4, from: .standardInput) else { return nil }
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= PluginHostFrameCodec.maximumFrameBytes else {
        throw PluginHostFrameError.frameTooLarge
    }
    guard let payload = readExactly(Int(length), from: .standardInput) else {
        throw PluginHostFrameError.incompleteFrame
    }
    var frame = header
    frame.append(payload)
    return try PluginHostFrameCodec.decode(PluginHostRequest.self, from: frame)
}

@MainActor
func response(for request: PluginHostRequest) -> PluginHostResponse {
    do {
        switch request.method {
        case .handshake:
            let payload = try JSONSerialization.data(withJSONObject: [
                "protocol_version": 1,
                "wasmtime_version": runtime.runtimeVersion,
                "maximum_frame_bytes": PluginHostFrameCodec.maximumFrameBytes,
                "ambient_wasi": false,
            ], options: [.sortedKeys])
            return PluginHostResponse(id: request.id, ok: true, payload: payload)
        case .validatePackage:
            guard let path = request.pluginPath else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing pluginPath")
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            let payload = try JSONEncoder().encode(package.manifest)
            return PluginHostResponse(id: request.id, ok: true, payload: payload)
        case .load:
            guard let path = request.pluginPath else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing pluginPath")
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            let executionCopy = try stagedExecutionCopy(of: package)
            do {
                try runtime.validateComponent(executionCopy, limits: limits)
            } catch {
                try? FileManager.default.removeItem(at: executionCopy.rootURL)
                throw error
            }
            if let previous = loadedPackages[package.manifest.id] {
                runtime.interrupt(pluginID: previous.executionCopy.manifest.id)
                try? FileManager.default.removeItem(at: previous.executionCopy.rootURL)
            }
            loadedPackages[package.manifest.id] = LoadedPlugin(source: package,
                                                               executionCopy: executionCopy)
            return PluginHostResponse(id: request.id,
                                      ok: true,
                                      payload: try JSONEncoder().encode(package.manifest))
        case .discover:
            guard let path = request.pluginPath else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing pluginPath")
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            guard let loaded = loadedPackages[package.manifest.id],
                  packagesMatch(loaded.source, package) else {
                return PluginHostResponse(id: request.id, ok: false,
                                          error: "plugin must be loaded and unchanged before discovery")
            }
            let payload = try runtime.discover(loaded.executionCopy, limits: limits)
            guard payload.count <= limits.maximumOutputBytes else { throw PluginHostFrameError.frameTooLarge }
            return PluginHostResponse(id: request.id, ok: true, payload: payload)
        case .prepare:
            guard let path = request.pluginPath,
                  let capabilityID = request.capabilityID,
                  let input = request.input else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing prepare arguments")
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            guard let loaded = loadedPackages[package.manifest.id],
                  packagesMatch(loaded.source, package) else {
                return PluginHostResponse(id: request.id, ok: false,
                                          error: "plugin package changed after loading")
            }
            let rawPayload = try runtime.prepare(loaded.executionCopy,
                                                 capabilityID: capabilityID,
                                                 input: input,
                                                 limits: limits)
            guard rawPayload.count <= limits.maximumOutputBytes else {
                throw PluginHostFrameError.frameTooLarge
            }
            if package.manifest.access == .read {
                // Read results are untrusted model context, never transaction
                // input. Requiring valid JSON keeps the RPC type bounded while
                // allowing analysis plugins to return structured findings.
                guard (try? JSONSerialization.jsonObject(with: rawPayload,
                                                         options: [.fragmentsAllowed])) != nil else {
                    throw PluginHostStagingError.invalidReadResult
                }
                return PluginHostResponse(id: request.id, ok: true, payload: rawPayload)
            }
            // The process boundary never forwards an opaque plugin-defined
            // mutation. Write preparation must decode to the only supported
            // host-call type and pass exact manifest/registry authority checks.
            let calls = try JSONDecoder().decode([HostCapabilityCall].self, from: rawPayload)
            let validated = try PluginCompositionValidator.validate(
                calls,
                manifest: package.manifest,
                registry: capabilityRegistry,
                limits: limits
            )
            return PluginHostResponse(id: request.id,
                                      ok: true,
                                      payload: try JSONEncoder().encode(validated))
        case .unload:
            if let path = request.pluginPath {
                let sourceRoot = URL(fileURLWithPath: path).standardizedFileURL
                if let entry = loadedPackages.first(where: { $0.value.source.rootURL == sourceRoot }) {
                    runtime.interrupt(pluginID: entry.value.executionCopy.manifest.id)
                    try? FileManager.default.removeItem(at: entry.value.executionCopy.rootURL)
                    loadedPackages.removeValue(forKey: entry.key)
                }
            }
            return PluginHostResponse(id: request.id, ok: true)
        }
    } catch {
        return PluginHostResponse(id: request.id, ok: false, error: String(describing: error))
    }
}

while true {
    do {
        guard let request = try readRequest() else { break }
        let frame = try PluginHostFrameCodec.encode(response(for: request))
        FileHandle.standardOutput.write(frame)
    } catch {
        FileHandle.standardError.write(Data("GuavaPluginHost: \(error)\n".utf8))
        break
    }
}
try? FileManager.default.removeItem(at: stagingRoot)
