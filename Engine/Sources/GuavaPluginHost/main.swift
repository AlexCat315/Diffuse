private import GuavaFileSystem
import Foundation
import GuavaLogging
private var loggingConfiguration = LoggingConfiguration()
try loggingConfiguration.applyEnvironment(ProcessInfo.processInfo.environment)
try LogSystem.bootstrap(configuration: loggingConfiguration)
defer { LogSystem.flush() }
import IntentRuntime
import CapabilityRuntime
import PluginRuntime
import PluginWasmtimeRuntime

private func createSecureDirectory(at url: URL,
                                   withIntermediateDirectories: Bool) throws {
    try FilePermissions.createPrivateDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
}

let processService = PluginProcessService()
let httpService = PluginHTTPService()
let runtime = try EmbeddedWasmtimeComponentRuntime(processes: processService,
                                                   http: httpService)
let runtimeMode = runtime.usesInterpreter ? "embedded-pulley" : "embedded"
let capabilityRegistry = CapabilityRegistry.aiDefault
let loader = PluginPackageLoader(registry: capabilityRegistry)
let limits = PluginResourceLimits.secureDefault
if CommandLine.arguments.count > 1 {
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--compile-component" {
        let source = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        try AtomicFile.write(EmbeddedWasmtimeComponentRuntime.compileComponentWAT(source), to: URL(fileURLWithPath: CommandLine.arguments[3]))
        exit(0)
    }
    // `guava plugin build`: the shell and guest bindings for a WIT contract,
    // then the shell compiled around the guest's core module.
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--component-shell" {
        let contract = try WITContractParser.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
                                                   grantedImports: Set(PluginImportPermission.allCases))
        let shell = try PluginComponentBuild.shell(for: contract)
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try AtomicFile.write(Data(shell.wat.utf8), to: directory.appendingPathComponent("shell.wat"))
        try AtomicFile.write(Data(shell.bindings.utf8), to: directory.appendingPathComponent("Exports.swift"))
        exit(0)
    }
    if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--link-component" {
        let shell = try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(
            String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))
        let core = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        try AtomicFile.write(PluginComponentBuild.link(shell: shell, core: core), to: URL(fileURLWithPath: CommandLine.arguments[4]))
        exit(0)
    }
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-web" else {
        throw WebPackageExportError.usage
    }
    do {
        try exportWebPackage(at: URL(fileURLWithPath: CommandLine.arguments[2]),
                             loader: loader, runtime: runtime, limits: limits, registry: capabilityRegistry)
        exit(0)
    } catch {
        LogSystem.logger("com.guava.engine.plugin").error("Web package validation failed: \(error)")
        LogSystem.flush()
        exit(1)
    }
}
let stagingRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("GuavaPluginHost-\(UUID().uuidString)", isDirectory: true)
try? createSecureDirectory(at: stagingRoot, withIntermediateDirectories: true)

struct LoadedPlugin {
    var source: ValidatedPluginPackage
    var executionCopy: ValidatedPluginPackage
    var inspection: PluginInspection
    var authorization: PluginAuthorizationRecord
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
        && lhs.runtime?.witContract == rhs.runtime?.witContract
        && lhs.runtime?.componentHash == rhs.runtime?.componentHash
        && lhs.runtime?.witHash == rhs.runtime?.witHash
        && lhs.resourceHashes == rhs.resourceHashes
}

/// Execute only a host-owned copy. Re-hashing the copy closes the window where
/// an untrusted local package could replace component.wasm after validation but
/// before Wasmtime opens it.
func stagedExecutionCopy(of package: ValidatedPluginPackage) throws -> ValidatedPluginPackage {
    let destination = stagingRoot
        .appendingPathComponent("\(package.manifest.id)-\(UUID().uuidString).guavaplugin",
                               isDirectory: true)
    try createSecureDirectory(at: destination, withIntermediateDirectories: false)
    do {
        for name in ["plugin.json", "component.wasm", "capabilities.wit"] + (package.resourceHashes.isEmpty ? [] : ["resources"]) {
            try FileManager.default.copyItem(at: package.rootURL.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }
        let copy = try loader.load(at: destination)
        guard copy.manifest == package.manifest,
              copy.runtime?.witContract == package.runtime?.witContract,
              copy.runtime?.componentHash == package.runtime?.componentHash,
              copy.runtime?.witHash == package.runtime?.witHash,
              copy.resourceHashes == package.resourceHashes else {
            throw PluginHostStagingError.packageChangedDuringStaging
        }
        return copy
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}

func inspectExecutionCopy(of package: ValidatedPluginPackage) throws
    -> (ValidatedPluginPackage, PluginInspection) {
    let executionCopy = try stagedExecutionCopy(of: package)
    do {
        try runtime.validateComponent(executionCopy, limits: limits)
        let contracts = PluginWITContractDeriver.contracts(for: executionCopy)
        return (executionCopy,
                PluginInspection(package: package, contracts: contracts))
    } catch {
        try? FileManager.default.removeItem(at: executionCopy.rootURL)
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
                "protocol_version": 5,
                "wasmtime_version": runtime.runtimeVersion,
                "runtime_mode": runtimeMode,
                "maximum_frame_bytes": PluginHostFrameCodec.maximumFrameBytes,
                "ambient_wasi": false,
            ], options: [.sortedKeys])
            return PluginHostResponse(id: request.id, ok: true, payload: payload)
        case .validatePackage:
            guard let path = request.pluginPath else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing pluginPath")
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            let (executionCopy, inspection) = try inspectExecutionCopy(of: package)
            defer { try? FileManager.default.removeItem(at: executionCopy.rootURL) }
            let payload = try JSONEncoder().encode(inspection)
            guard payload.count <= limits.maximumOutputBytes else {
                throw PluginHostFrameError.frameTooLarge
            }
            return PluginHostResponse(id: request.id, ok: true, payload: payload)
        case .load:
            guard let path = request.pluginPath else {
                return PluginHostResponse(id: request.id, ok: false, error: "missing pluginPath")
            }
            guard let authorization = request.authorization else {
                throw PluginAuthorizationError.missing
            }
            let package = try loader.load(at: URL(fileURLWithPath: path))
            let (executionCopy, inspection) = try inspectExecutionCopy(of: package)
            guard authorization.isStillValid(for: inspection) else {
                try? FileManager.default.removeItem(at: executionCopy.rootURL)
                throw PluginAuthorizationError.noLongerValid
            }
            if let previous = loadedPackages[package.manifest.id] {
                processService.unmount(pluginID: package.manifest.id)
                httpService.unmount(pluginID: package.manifest.id)
                runtime.interrupt(pluginID: previous.executionCopy.manifest.id)
                try? FileManager.default.removeItem(at: previous.executionCopy.rootURL)
            }
            if !package.manifest.host.processes.isEmpty {
                guard let context = request.processContext else { throw PluginProcessError.notAuthorized }
                try processService.mount(inspection: inspection, authorization: authorization, context: context)
            }
            if !package.manifest.host.http.isEmpty {
                try httpService.mount(inspection: inspection, authorization: authorization)
            }
            loadedPackages[package.manifest.id] = LoadedPlugin(source: package,
                                                               executionCopy: executionCopy,
                                                               inspection: inspection,
                                                               authorization: authorization)
            return PluginHostResponse(id: request.id,
                                      ok: true,
                                      payload: try JSONEncoder().encode(inspection))
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
            guard request.authorization == loaded.authorization,
                  loaded.authorization.isStillValid(for: loaded.inspection) else {
                throw PluginAuthorizationError.noLongerValid
            }
            let payload = try JSONEncoder().encode(
                PluginCapabilityDiscovery(
                    capabilityIDs: loaded.inspection.contracts.map(\.id)
                )
            )
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
            guard request.authorization == loaded.authorization,
                  loaded.authorization.isStillValid(for: loaded.inspection) else {
                throw PluginAuthorizationError.noLongerValid
            }
            guard let contract = loaded.inspection.contracts.first(where: {
                $0.id == capabilityID
            }) else {
                throw PluginCapabilityValidationError.unknownCapability(capabilityID)
            }
            // Editor entry points take whole tool output; the runtime checks their
            // shape without length bounds.
            let entryPoint = String(capabilityID.dropFirst(package.manifest.id.count + 1))
            let invocationLimits = package.limits(for: entryPoint, default: limits)
            if !package.isHostEntryPoint(entryPoint) {
                try JSONSchemaValidator.validate(data: input, against: contract.inputSchema)
            }
            let rawPayload = try runtime.prepare(loaded.executionCopy,
                                                 capabilityID: capabilityID,
                                                 input: input,
                                                 querySnapshot: request.querySnapshot,
                                                 limits: invocationLimits)
            guard rawPayload.count <= invocationLimits.maximumOutputBytes else {
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
                    processService.unmount(pluginID: entry.key)
                    httpService.unmount(pluginID: entry.key)
                    runtime.interrupt(pluginID: entry.value.executionCopy.manifest.id)
                    try? FileManager.default.removeItem(at: entry.value.executionCopy.rootURL)
                    loadedPackages.removeValue(forKey: entry.key)
                }
            }
            return PluginHostResponse(id: request.id, ok: true)
        }
    } catch {
        LogSystem.logger("com.guava.engine.plugin").warning("Plugin request rejected", metadata: ["method": "\(request.method)", "error": "\(error)"])
        return PluginHostResponse(id: request.id, ok: false, error: String(describing: error))
    }
}

while true {
    do {
        guard let request = try readRequest() else { break }
        let frame = try PluginHostFrameCodec.encode(response(for: request))
        FileHandle.standardOutput.write(frame)
    } catch {
        LogSystem.logger("com.guava.engine.plugin").error("Plugin host protocol failed", metadata: ["error": "\(error)"])
        LogSystem.flush()
        break
    }
}
for pluginID in loadedPackages.keys {
    processService.unmount(pluginID: pluginID)
    httpService.unmount(pluginID: pluginID)
}
try? FileManager.default.removeItem(at: stagingRoot)
