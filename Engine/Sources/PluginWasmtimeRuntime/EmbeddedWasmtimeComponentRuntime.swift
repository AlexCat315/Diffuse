import CWasmtimeBridge
import Foundation
import PluginRuntime

public enum EmbeddedWasmtimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case initialisationFailed(String)
    case bridge(status: Int32, message: String)
    case wallClockTimeout

    public var description: String {
        switch self {
        case let .initialisationFailed(message):
            return "could not initialise embedded Wasmtime: \(message)"
        case let .bridge(status, message):
            return "embedded Wasmtime failed (\(status)): \(message)"
        case .wallClockTimeout:
            return "embedded Wasmtime Component invocation exceeded its wall-clock limit"
        }
    }
}

/// Wasmtime v45 Component Model embedding used exclusively inside the
/// GuavaPluginHost process. The bridge creates a fresh Store per call, links
/// no WASI interfaces, and exposes only manifest-granted Guava query imports.
public final class EmbeddedWasmtimeComponentRuntime: WASIComponentRuntime, @unchecked Sendable {
    public let runtimeVersion: String

    private let runtime: OpaquePointer
    private let invocationLock = NSLock()

    public init() throws {
        var error = guava_wasmtime_buffer_t(data: nil, size: 0)
        guard let runtime = guava_wasmtime_runtime_new(&error) else {
            let message = Self.consume(&error)
            throw EmbeddedWasmtimeError.initialisationFailed(message)
        }
        self.runtime = runtime
        runtimeVersion = String(cString: guava_wasmtime_runtime_version())
    }

    deinit {
        guava_wasmtime_runtime_delete(runtime)
    }

    public func validateComponent(_ package: ValidatedPluginPackage,
                                  limits: PluginResourceLimits) throws {
        try invocationLock.withLock {
            try withDeadline(milliseconds: limits.discoveryTimeoutMilliseconds) { deadline in
                var error = guava_wasmtime_buffer_t(data: nil, size: 0)
                var enforcedLimits = bridgeLimitsValue(limits)
                let status = withImportNames(package.witContract.imports) { names, count in
                    package.componentURL.path.withCString { path in
                        guava_wasmtime_validate_component(
                            runtime,
                            path,
                            names,
                            count,
                            &enforcedLimits,
                            &error
                        )
                    }
                }
                try check(status: status, error: &error, deadline: deadline)
            }
        }
    }

    public func discover(_ package: ValidatedPluginPackage,
                         limits: PluginResourceLimits) throws -> Data {
        try invocationLock.withLock {
            try invoke(
                package: package,
                exportName: "discover",
                arguments: [],
                querySnapshot: nil,
                timeoutMilliseconds: limits.discoveryTimeoutMilliseconds,
                limits: limits
            )
        }
    }

    public func prepare(_ package: ValidatedPluginPackage,
                        capabilityID: String,
                        input: Data,
                        querySnapshot: PluginQuerySnapshot?,
                        limits: PluginResourceLimits) throws -> Data {
        guard input.count <= limits.maximumOutputBytes else {
            throw EmbeddedWasmtimeError.bridge(
                status: Int32(GUAVA_WASMTIME_INVALID_ARGUMENT.rawValue),
                message: "Component input exceeds 1 MiB"
            )
        }
        let grantedImports = Set(package.manifest.imports)
        if !grantedImports.isEmpty {
            guard let querySnapshot else {
                throw PluginQuerySnapshotError.missingPayload(package.manifest.imports[0])
            }
            try querySnapshot.validate(for: grantedImports)
        }
        return try invocationLock.withLock {
            try invoke(
                package: package,
                exportName: "prepare",
                arguments: [Data(capabilityID.utf8), input],
                querySnapshot: querySnapshot,
                timeoutMilliseconds: limits.preparationTimeoutMilliseconds,
                limits: limits
            )
        }
    }

    public func interrupt(pluginID: String) {
        guava_wasmtime_runtime_interrupt(runtime)
    }

    private func invoke(package: ValidatedPluginPackage,
                        exportName: String,
                        arguments: [Data],
                        querySnapshot: PluginQuerySnapshot?,
                        timeoutMilliseconds: UInt64,
                        limits: PluginResourceLimits) throws -> Data {
        let environment = QueryEnvironment(
            snapshot: querySnapshot,
            grantedImports: Set(package.manifest.imports)
        )
        return try withDeadline(milliseconds: timeoutMilliseconds) { deadline in
            var output = guava_wasmtime_buffer_t(data: nil, size: 0)
            var error = guava_wasmtime_buffer_t(data: nil, size: 0)
            var enforcedLimits = bridgeLimitsValue(limits)
            let status = withImportNames(package.witContract.imports) { names, importCount in
                withArgumentData(arguments) { argumentPointers, argumentSizes, argumentCount in
                    package.componentURL.path.withCString { path in
                        exportName.withCString { exportedFunction in
                            guava_wasmtime_invoke_component(
                                runtime,
                                path,
                                exportedFunction,
                                argumentPointers,
                                argumentSizes,
                                argumentCount,
                                names,
                                importCount,
                                embeddedQueryCallback,
                                Unmanaged.passUnretained(environment).toOpaque(),
                                &enforcedLimits,
                                &output,
                                &error
                            )
                        }
                    }
                }
            }
            try check(status: status, error: &error, deadline: deadline)
            defer { guava_wasmtime_buffer_delete(&output) }
            guard let bytes = output.data else { return Data() }
            return Data(bytes: bytes, count: output.size)
        }
    }

    private func check(status: guava_wasmtime_status_t,
                       error: inout guava_wasmtime_buffer_t,
                       deadline: InvocationDeadline) throws {
        let message = Self.consume(&error)
        guard status == GUAVA_WASMTIME_OK else {
            if deadline.didFire {
                throw EmbeddedWasmtimeError.wallClockTimeout
            }
            throw EmbeddedWasmtimeError.bridge(
                status: Int32(status.rawValue),
                message: message.isEmpty ? "unknown Component error" : message
            )
        }
    }

    private func withDeadline<T>(milliseconds: UInt64,
                                 operation: (InvocationDeadline) throws -> T) throws -> T {
        let deadline = InvocationDeadline(runtime: runtime)
        let clamped = min(milliseconds, UInt64(Int.max))
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        // Compilation itself is not epoch-interruptible. Repeating after the
        // deadline ensures that if compilation finishes late, the newly
        // created Store is still interrupted as soon as execution begins.
        timer.schedule(deadline: .now() + .milliseconds(Int(clamped)),
                       repeating: .milliseconds(10))
        timer.setEventHandler {
            deadline.fire()
        }
        timer.resume()
        defer {
            deadline.deactivate()
            timer.cancel()
        }
        return try operation(deadline)
    }

    private func bridgeLimitsValue(_ limits: PluginResourceLimits) -> guava_wasmtime_limits_t {
        guava_wasmtime_limits_t(
            maximum_memory_bytes: limits.maximumMemoryBytes,
            fuel_per_invocation: limits.fuelPerInvocation,
            maximum_table_elements: 100_000,
            maximum_instances: 64,
            maximum_tables: 16,
            maximum_memories: 16,
            maximum_output_bytes: limits.maximumOutputBytes,
            maximum_query_request_bytes: PluginQuerySnapshot.maximumRequestBytes
        )
    }

    private func withImportNames<T>(
        _ names: [String],
        body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) throws -> T
    ) rethrows -> T {
        let allocations: [UnsafeMutablePointer<CChar>] = names.map { name in
            let bytes = Array(name.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer {
            for (pointer, name) in zip(allocations, names) {
                pointer.deinitialize(count: name.utf8CString.count)
                pointer.deallocate()
            }
        }
        let pointers: [UnsafePointer<CChar>?] = allocations.map { UnsafePointer($0) }
        return try pointers.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress, buffer.count)
        }
    }

    private func withArgumentData<T>(
        _ arguments: [Data],
        body: (UnsafePointer<UnsafePointer<UInt8>?>?, UnsafePointer<Int>?, Int) throws -> T
    ) rethrows -> T {
        let retained = arguments.map { $0 as NSData }
        let pointers: [UnsafePointer<UInt8>?] = retained.map { value in
            guard value.length > 0 else { return nil }
            return value.bytes.assumingMemoryBound(to: UInt8.self)
        }
        let sizes = retained.map(\.length)
        return try pointers.withUnsafeBufferPointer { pointerBuffer in
            try sizes.withUnsafeBufferPointer { sizeBuffer in
                try body(pointerBuffer.baseAddress,
                         sizeBuffer.baseAddress,
                         pointerBuffer.count)
            }
        }
    }

    private static func consume(_ buffer: inout guava_wasmtime_buffer_t) -> String {
        defer { guava_wasmtime_buffer_delete(&buffer) }
        guard let bytes = buffer.data, buffer.size > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: buffer.size),
                      as: UTF8.self)
    }

    static func compileComponentWAT(_ source: String) throws -> Data {
        var output = guava_wasmtime_buffer_t(data: nil, size: 0)
        var error = guava_wasmtime_buffer_t(data: nil, size: 0)
        let sourceData = Data(source.utf8)
        let status = sourceData.withUnsafeBytes { bytes in
            guava_wasmtime_component_wat2wasm(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output,
                &error
            )
        }
        let message = consume(&error)
        guard status == GUAVA_WASMTIME_OK else {
            guava_wasmtime_buffer_delete(&output)
            throw EmbeddedWasmtimeError.bridge(
                status: Int32(status.rawValue),
                message: message
            )
        }
        defer { guava_wasmtime_buffer_delete(&output) }
        guard let bytes = output.data else { return Data() }
        return Data(bytes: bytes, count: output.size)
    }
}

private final class InvocationDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: OpaquePointer
    private var active = true
    private var fired = false

    init(runtime: OpaquePointer) {
        self.runtime = runtime
    }

    var didFire: Bool { lock.withLock { fired } }

    func fire() {
        lock.withLock {
            guard active else { return }
            fired = true
            guava_wasmtime_runtime_interrupt(runtime)
        }
    }

    func deactivate() {
        lock.withLock { active = false }
    }
}

private final class QueryEnvironment: @unchecked Sendable {
    let snapshot: PluginQuerySnapshot?
    let grantedImports: Set<PluginImportPermission>

    init(snapshot: PluginQuerySnapshot?,
         grantedImports: Set<PluginImportPermission>) {
        self.snapshot = snapshot
        self.grantedImports = grantedImports
    }

    func response(importName: String, request: Data) throws -> Data {
        guard let snapshot else {
            throw PluginQuerySnapshotError.importNotGranted(importName)
        }
        return try snapshot.response(importName: importName,
                                     request: request,
                                     grantedImports: grantedImports)
    }
}

private let embeddedQueryCallback: guava_wasmtime_query_callback_t = {
    environment,
    interfaceName,
    interfaceNameSize,
    request,
    requestSize,
    response,
    errorBuffer in
    guard let environment,
          let interfaceName,
          let response,
          let errorBuffer else { return -1 }
    let dispatcher = Unmanaged<QueryEnvironment>
        .fromOpaque(environment)
        .takeUnretainedValue()
    let importName = String(
        decoding: UnsafeBufferPointer(start: interfaceName,
                                      count: interfaceNameSize),
        as: UTF8.self
    )
    let requestData: Data
    if let request, requestSize > 0 {
        requestData = Data(bytes: request, count: requestSize)
    } else {
        requestData = Data()
    }
    do {
        let payload = try dispatcher.response(importName: importName,
                                              request: requestData)
        return payload.withUnsafeBytes { bytes in
            guava_wasmtime_buffer_copy(
                response,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            ) == 0 ? 0 : -1
        }
    } catch let queryError {
        let diagnostic = Data(String(describing: queryError).utf8)
        _ = diagnostic.withUnsafeBytes { bytes in
            guava_wasmtime_buffer_copy(
                errorBuffer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        return -1
    }
}
