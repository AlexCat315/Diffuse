import CapabilityRuntime
import Foundation
@testable import PluginRuntime
#if canImport(PluginWasmtimeRuntime)
@testable import PluginWasmtimeRuntime
#endif
import Testing

@Suite("PluginRuntime security boundary")
struct PluginRuntimeTests {
    @Test("length-prefixed RPC rejects trailing and oversized frames")
    func frameCodecIsStrict() throws {
        let request = PluginHostRequest(method: .handshake)
        let frame = try PluginHostFrameCodec.encode(request)
        #expect(try PluginHostFrameCodec.decode(PluginHostRequest.self, from: frame) == request)

        var trailing = frame
        trailing.append(0)
        #expect(throws: PluginHostFrameError.trailingBytes) {
            try PluginHostFrameCodec.decode(PluginHostRequest.self, from: trailing)
        }
        var oversized = Data([0x00, 0x10, 0x00, 0x01])
        oversized.append(Data(repeating: 0, count: 4))
        #expect(throws: PluginHostFrameError.frameTooLarge) {
            try PluginHostFrameCodec.decode(PluginHostRequest.self, from: oversized)
        }
    }

    @Test("WIT filesystem imports are denied even when not declared")
    func witDeniesAmbientWASI() {
        let wit = """
        package example:safe;
        world plugin {
          import wasi:filesystem/types;
          export discover: func() -> list<u8>;
          export prepare: func(input: list<u8>) -> list<u8>;
        }
        """
        #expect(throws: WITContractError.forbiddenImport("wasi:filesystem/types")) {
            try WITContractParser.parse(Data(wit.utf8), grantedImports: [])
        }
    }

    @Test("WIT accepts only the exact typed plugin ABI")
    func witAcceptsExactPluginABI() throws {
        let wit = """
        package example:safe;
        world plugin {
          export discover: func() -> string;
          export prepare: func(capability-id: string, input: string) -> string;
        }
        """
        let contract = try WITContractParser.parse(Data(wit.utf8), grantedImports: [])
        #expect(contract.worldName == "plugin")
        #expect(contract.exports.map(\.name) == ["discover", "prepare"])

        let loose = """
        package example:unsafe;
        world plugin {
          export discover: func() -> string;
          export prepare: func(input: string) -> string;
        }
        """
        #expect(throws: WITContractError.malformedDeclaration(
            "prepare must be func(capability-id: string, input: string) -> string"
        )) {
            try WITContractParser.parse(Data(loose.utf8), grantedImports: [])
        }

        let twoWorlds = wit + "\nworld second {}"
        #expect(throws: WITContractError.malformedDeclaration("exactly one world is required")) {
            try WITContractParser.parse(Data(twoWorlds.utf8), grantedImports: [])
        }
    }

    @Test("plugin metadata is sanitised before authority validation")
    func metadataSanitisationFailsClosed() {
        let manifest = """
        {
          "id": "safe.reader",
          "version": 1,
          "name": "\\u0001\\u0002",
          "description": "untrusted\\u0000text",
          "access": "read",
          "imports": [],
          "composable_host_capabilities": []
        }
        """
        #expect(throws: PluginManifestValidationError.emptyName) {
            try PluginManifestValidator.decodeAndValidate(Data(manifest.utf8))
        }
    }

    @Test("Wasmtime invocation disables the ambient WASI linker surface")
    func wasmtimeArgumentsDisableAmbientWASI() {
        let arguments = WasmtimeCLIComponentRuntime.invocationArguments(
            componentPath: "/plugin/component.wasm",
            expression: "discover()",
            timeoutMilliseconds: 2_000,
            limits: .secureDefault
        )
        let wasiOptions = arguments.dropFirst()
            .first { $0.contains("common=n") }
        #expect(wasiOptions?.contains("cli=n") == true)
        #expect(wasiOptions?.contains("http=n") == true)
        #expect(wasiOptions?.contains("inherit-env=n") == true)
        #expect(wasiOptions?.contains("inherit-network=n") == true)
        #expect(arguments.contains("fuel=20000000"))
        #expect(arguments.contains("max-memory-size=67108864"))
        #expect(arguments.contains("timeout=2000ms"))
        #expect(arguments.contains {
            $0.contains("max-instances=64") && $0.contains("max-memories=16")
        })
        #expect(arguments.last == "/plugin/component.wasm")
    }

    @Test("Wasmtime CLI accepts only the exact pinned release")
    func wasmtimeVersionMatchIsExact() {
        #expect(WasmtimeCLIComponentRuntime.isPinnedVersionOutput("wasmtime 45.0.0\n"))
        #expect(WasmtimeCLIComponentRuntime.isPinnedVersionOutput("wasmtime 45.0.0 build-hash"))
        #expect(!WasmtimeCLIComponentRuntime.isPinnedVersionOutput("wasmtime 145.0.0"))
        #expect(!WasmtimeCLIComponentRuntime.isPinnedVersionOutput("wasmtime 45.0.0-rc.1"))
    }

    @Test("CLI runtime rejects custom host imports until an embedded linker is available")
    func cliRuntimeRejectsUnlinkedGuavaImports() throws {
        try WasmtimeCLIComponentRuntime.validateSupportedImports([])
        #expect(throws: WasmtimeCLIError.unsupportedHostImports(["guava:scene/query"])) {
            try WasmtimeCLIComponentRuntime.validateSupportedImports(["guava:scene/query"])
        }
    }

    @Test("oversized component output is drained and rejected without pipe deadlock")
    func oversizedWasmtimeOutputFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-wasmtime")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'wasmtime 45.0.0\\n'
          exit 0
        fi
        printf '"'
        dd if=/dev/zero bs=1100000 count=1 2>/dev/null | tr '\\000' 'a'
        printf '"\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        let runtime = try WasmtimeCLIComponentRuntime(executableURL: executable)
        let package = ValidatedPluginPackage(
            rootURL: root,
            manifest: GuavaPluginManifest(
                id: "safe.reader",
                version: 1,
                name: "Reader",
                description: "Test reader",
                access: .read
            ),
            componentURL: root.appendingPathComponent("component.wasm"),
            witURL: root.appendingPathComponent("capabilities.wit"),
            witContract: WITContract(
                worldName: "plugin",
                imports: [],
                exports: [
                    WITFunctionExport(name: "discover", signature: "func() -> string"),
                    WITFunctionExport(
                        name: "prepare",
                        signature: "func(capability-id: string, input: string) -> string"
                    ),
                ]
            ),
            componentHash: "test",
            witHash: "test"
        )
        #expect(throws: WasmtimeCLIError.outputTooLarge) {
            try runtime.discover(package, limits: .secureDefault)
        }
    }

    @Test("plugin composition cannot call an ungranted primitive")
    func compositionRequiresExactGrant() throws {
        let contract = try #require(CapabilityRegistry.default.descriptor(for: "scene.set_transform")?.contract)
        let arguments = try JSONSerialization.data(withJSONObject: [
            "entity_id": "scene:1",
            "position": [0, 1, 2],
        ], options: [.sortedKeys])
        let call = HostCapabilityCall(capabilityID: contract.id,
                                      version: contract.version,
                                      arguments: arguments)
        let manifest = GuavaPluginManifest(id: "safe.layout",
                                           version: 1,
                                           name: "Safe layout",
                                           description: "Layout helper",
                                           access: .reversibleWrite,
                                           composableHostCapabilities: [])
        #expect(throws: PluginCompositionError.capabilityNotGranted(contract.id)) {
            try PluginCompositionValidator.validate([call], manifest: manifest)
        }

        let understated = GuavaPluginManifest(
            id: "safe.layout",
            version: 1,
            name: "Safe layout",
            description: "Layout helper",
            access: .reversibleWrite,
            composableHostCapabilities: ["scene.delete_entity"]
        )
        #expect(throws: PluginManifestValidationError.accessUnderstatement(
            capabilityID: "scene.delete_entity"
        )) {
            try PluginManifestValidator.validate(understated)
        }
    }

    @Test("package loader requires a component binary and fixed files")
    func packageLoaderValidatesComponentModelHeader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("guavaplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {
          "id": "safe.reader",
          "version": 1,
          "name": "Reader",
          "description": "Read-only example",
          "access": "read",
          "imports": [],
          "composable_host_capabilities": []
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.json"))
        try Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
            .write(to: root.appendingPathComponent("component.wasm"))
        let wit = """
        package example:safe;
        world plugin {
          export discover: func() -> list<u8>;
          export prepare: func(input: list<u8>) -> list<u8>;
        }
        """
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))

        #expect(throws: PluginPackageError.invalidComponentHeader) {
            try PluginPackageLoader().load(at: root)
        }
    }

#if canImport(PluginWasmtimeRuntime)
    @Test("embedded Wasmtime validates and invokes the exact plugin ABI")
    func embeddedRuntimeInvokesRealComponent() throws {
        let package = try makePluginPackage(
            componentWAT: Self.constantResultComponentWAT,
            imports: []
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime()

        try runtime.validateComponent(package, limits: .secureDefault)
        let discovery = try runtime.discover(package, limits: .secureDefault)
        let prepared = try runtime.prepare(
            package,
            capabilityID: "safe.reader.inspect",
            input: Data("{}".utf8),
            querySnapshot: nil,
            limits: .secureDefault
        )

        #expect(runtime.runtimeVersion == "45.0.0")
        #expect(String(decoding: discovery, as: UTF8.self) == #"{"capabilities":[]}"#)
        #expect(String(decoding: prepared, as: UTF8.self) == "[]")
    }

    @Test("isolated GuavaPluginHost loads and invokes a real Component over RPC")
    func pluginHostEndToEnd() throws {
        let package = try makePluginPackage(
            componentWAT: Self.constantResultComponentWAT,
            imports: []
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let executable = try #require(builtExecutable(named: "GuavaPluginHost"))
        let client = PluginHostProcessClient(executableURL: executable)
        defer { client.stop() }

        let handshake = try client.call(PluginHostRequest(method: .handshake))
        let handshakePayload = try #require(handshake.payload)
        let handshakeJSON = try #require(
            JSONSerialization.jsonObject(with: handshakePayload) as? [String: Any]
        )
        #expect(handshake.ok)
        #expect(handshakeJSON["protocol_version"] as? Int == 3)
        #expect(handshakeJSON["wasmtime_version"] as? String == "45.0.0")
        #expect(handshakeJSON["runtime_mode"] as? String == "embedded")
        #expect(handshakeJSON["ambient_wasi"] as? Bool == false)

        let path = package.rootURL.path
        let inspectionResponse = try client.call(PluginHostRequest(
            method: .validatePackage,
            pluginPath: path
        ))
        let inspection = try JSONDecoder().decode(
            PluginInspection.self,
            from: try #require(inspectionResponse.payload)
        )
        #expect(inspectionResponse.ok)
        #expect(inspection.componentHash == package.componentHash)
        #expect(inspection.contracts.isEmpty)

        let unauthorized = try client.call(PluginHostRequest(method: .load,
                                                             pluginPath: path))
        #expect(!unauthorized.ok)
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        let loaded = try client.call(PluginHostRequest(
            method: .load,
            pluginPath: path,
            authorization: authorization
        ))
        #expect(loaded.ok)
        let discovery = try client.call(PluginHostRequest(
            method: .discover,
            pluginPath: path,
            authorization: authorization
        ))
        #expect(discovery.ok)
        #expect(discovery.payload == Data(#"{"capabilities":[]}"#.utf8))

        let prepared = try client.call(PluginHostRequest(
            method: .prepare,
            pluginPath: path,
            capabilityID: "safe.reader.inspect",
            input: Data("{}".utf8),
            authorization: authorization
        ))
        #expect(prepared.ok)
        #expect(prepared.payload == Data("[]".utf8))

        let unloaded = try client.call(PluginHostRequest(method: .unload,
                                                         pluginPath: path))
        #expect(unloaded.ok)
    }
#endif

    @Test("query snapshots require granted structured payloads and an exact request")
    func querySnapshotIsStrict() throws {
        let scene = Data(#"{"entities":[]}"#.utf8)
        let snapshot = PluginQuerySnapshot(sceneRevision: 42, scene: scene)
        try snapshot.validate(for: [.sceneQuery])

        let response = try snapshot.response(
            importName: PluginImportPermission.sceneQuery.rawValue,
            request: Data(#"{"operation":"snapshot"}"#.utf8),
            grantedImports: [.sceneQuery]
        )
        #expect(response == scene)
        #expect(throws: PluginQuerySnapshotError.invalidRequest) {
            try snapshot.response(
                importName: PluginImportPermission.sceneQuery.rawValue,
                request: Data(#"{"operation":"snapshot","extra":true}"#.utf8),
                grantedImports: [.sceneQuery]
            )
        }
        #expect(throws: PluginQuerySnapshotError.missingPayload(.selectionQuery)) {
            try snapshot.validate(for: [.sceneQuery, .selectionQuery])
        }
    }

    @Test("plugin discovery and authorization bind code, WIT, permissions, and schemas")
    func pluginAuthorizationInvalidatesEveryAuthorityChange() throws {
        let package = ValidatedPluginPackage(
            rootURL: URL(fileURLWithPath: "/safe.reader.guavaplugin"),
            manifest: GuavaPluginManifest(
                id: "safe.reader",
                version: 1,
                name: "Reader",
                description: "Read a bounded snapshot",
                access: .read,
                imports: [.sceneQuery]
            ),
            componentURL: URL(fileURLWithPath: "/safe.reader.guavaplugin/component.wasm"),
            witURL: URL(fileURLWithPath: "/safe.reader.guavaplugin/capabilities.wit"),
            witContract: WITContract(worldName: "plugin",
                                     imports: ["guava:scene/query"],
                                     exports: []),
            componentHash: "component-a",
            witHash: "wit-a"
        )
        let contract = CapabilityContract(
            id: "safe.reader.inspect",
            title: "Inspect scene",
            description: "Returns bounded findings",
            domain: "scene",
            access: .read,
            releasePhase: .stable,
            inputSchema: .object(properties: [:]),
            source: .plugin("safe.reader")
        )
        let discovery = try JSONEncoder().encode(
            PluginCapabilityDiscovery(capabilities: [contract])
        )
        let validated = try PluginDiscoveryValidator.validate(discovery,
                                                              package: package)
        let inspection = PluginInspection(package: package, contracts: validated)
        let authorization = try PluginAuthorizationRecord(
            inspection: inspection,
            authorisedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(authorization.isStillValid(for: inspection))

        var changedCode = inspection
        changedCode.componentHash = "component-b"
        #expect(!authorization.isStillValid(for: changedCode))
        var changedWIT = inspection
        changedWIT.witHash = "wit-b"
        #expect(!authorization.isStillValid(for: changedWIT))
        var changedImports = inspection
        changedImports.manifest.imports = [.selectionQuery]
        #expect(!authorization.isStillValid(for: changedImports))
        var changedAccess = inspection
        changedAccess.manifest.access = .reversibleWrite
        #expect(!authorization.isStillValid(for: changedAccess))
        var changedSchema = inspection
        changedSchema.contracts[0] = CapabilityContract(
            id: contract.id,
            title: contract.title,
            description: contract.description,
            domain: contract.domain,
            access: contract.access,
            releasePhase: contract.releasePhase,
            inputSchema: .object(properties: ["query": .string()]),
            source: contract.source
        )
        #expect(!authorization.isStillValid(for: changedSchema))

        let duplicateDiscovery = try JSONEncoder().encode(
            PluginCapabilityDiscovery(capabilities: [contract, contract])
        )
        #expect(throws: PluginDiscoveryValidationError.duplicateCapability(contract.id)) {
            try PluginDiscoveryValidator.validate(duplicateDiscovery,
                                                  package: package)
        }
        var forgedHash = contract
        forgedHash.schemaHash = "forged"
        let forgedDiscovery = try JSONEncoder().encode(
            PluginCapabilityDiscovery(capabilities: [forgedHash])
        )
        #expect(throws: PluginDiscoveryValidationError.schemaHashMismatch(contract.id)) {
            try PluginDiscoveryValidator.validate(forgedDiscovery,
                                                  package: package)
        }
        let unsafePattern = CapabilityContract(
            id: contract.id,
            title: contract.title,
            description: contract.description,
            domain: contract.domain,
            access: contract.access,
            releasePhase: contract.releasePhase,
            inputSchema: .object(properties: [
                "query": JSONSchema(type: .string, pattern: "(a+)+$"),
            ]),
            source: contract.source
        )
        let unsafeDiscovery = try JSONEncoder().encode(
            PluginCapabilityDiscovery(capabilities: [unsafePattern])
        )
        #expect(throws: PluginDiscoveryValidationError.self) {
            try PluginDiscoveryValidator.validate(unsafeDiscovery,
                                                  package: package)
        }
    }

#if canImport(PluginWasmtimeRuntime)
    @Test("embedded Component can query only its granted revision-bound snapshot")
    func embeddedRuntimeDispatchesGrantedQueryImport() throws {
        let package = try makePluginPackage(
            componentWAT: Self.sceneQueryComponentWAT,
            imports: [.sceneQuery]
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime()
        let scene = Data(#"{"entities":[{"id":"scene:1"}]}"#.utf8)
        let snapshot = PluginQuerySnapshot(sceneRevision: 17, scene: scene)

        try runtime.validateComponent(package, limits: .secureDefault)
        let prepared = try runtime.prepare(
            package,
            capabilityID: "safe.reader.inspect",
            input: Data("{}".utf8),
            querySnapshot: snapshot,
            limits: .secureDefault
        )

        #expect(prepared == scene)
        #expect(throws: PluginQuerySnapshotError.missingPayload(.sceneQuery)) {
            try runtime.prepare(
                package,
                capabilityID: "safe.reader.inspect",
                input: Data("{}".utf8),
                querySnapshot: PluginQuerySnapshot(sceneRevision: 17),
                limits: .secureDefault
            )
        }
    }
#endif

#if canImport(PluginWasmtimeRuntime)
    @Test("Component imports must exactly match capabilities.wit")
    func embeddedRuntimeRejectsComponentWITMismatch() throws {
        let package = try makePluginPackage(
            componentWAT: Self.constantResultComponentWAT,
            imports: [.sceneQuery]
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime()

        #expect(throws: EmbeddedWasmtimeError.self) {
            try runtime.validateComponent(package, limits: .secureDefault)
        }
    }
#endif

#if canImport(PluginWasmtimeRuntime)
    @Test("fuel and epoch interruption bound a non-terminating Component")
    func embeddedRuntimeInterruptsInfiniteLoop() throws {
        let package = try makePluginPackage(
            componentWAT: Self.infinitePrepareComponentWAT,
            imports: []
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime()
        let limits = PluginResourceLimits(
            preparationTimeoutMilliseconds: 20,
            fuelPerInvocation: 20_000_000
        )
        let clock = ContinuousClock()
        let start = clock.now

        #expect(throws: EmbeddedWasmtimeError.self) {
            try runtime.prepare(
                package,
                capabilityID: "safe.reader.loop",
                input: Data("{}".utf8),
                querySnapshot: nil,
                limits: limits
            )
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
#endif

    @Test("Editor RPC client restarts a PluginHost that misses its deadline")
    func processClientDeadlineRestartsHost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("unresponsive-plugin-host")
        let script = """
        #!/bin/sh
        exec sleep 5
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        let client = PluginHostProcessClient(executableURL: executable)
        defer { client.stop() }
        let clock = ContinuousClock()
        let start = clock.now

        #expect(throws: PluginHostClientError.hostRestarted(generation: 1)) {
            try client.call(PluginHostRequest(method: .handshake),
                            timeoutMilliseconds: 50)
        }
        #expect(client.generation == 1)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

#if canImport(PluginWasmtimeRuntime)
    private func builtExecutable(named name: String) -> URL? {
        let launchLocations = [
            URL(fileURLWithPath: CommandLine.arguments[0]),
            Bundle.main.executableURL,
        ].compactMap { $0 }
        for launchLocation in launchLocations {
            var directory = launchLocation.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        let buildDirectories = (try? FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in buildDirectories {
            for candidate in [
                directory.appendingPathComponent(name),
                directory.appendingPathComponent("debug").appendingPathComponent(name),
            ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func makePluginPackage(componentWAT: String,
                                   imports: [PluginImportPermission]) throws -> ValidatedPluginPackage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("guavaplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = GuavaPluginManifest(
            id: "safe.reader",
            version: 1,
            name: "Reader",
            description: "Embedded runtime test",
            access: .read,
            imports: imports
        )
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("plugin.json"))
        try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(componentWAT)
            .write(to: root.appendingPathComponent("component.wasm"))
        let importLines = imports.map { "  import \($0.rawValue);" }
            .joined(separator: "\n")
        let wit = """
        package safe:reader;
        world plugin {
        \(importLines)
          export discover: func() -> string;
          export prepare: func(capability-id: string, input: string) -> string;
        }
        """
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))
        do {
            return try PluginPackageLoader().load(at: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static let constantResultComponentWAT = #"""
    (component
      (core module $guest
        (memory (export "memory") 1)
        (global $next (mut i32) (i32.const 4096))
        (data (i32.const 64) "{\22capabilities\22:[]}")
        (data (i32.const 96) "[]")

        (func $realloc (export "realloc")
          (param $old i32) (param $old-size i32)
          (param $align i32) (param $new-size i32) (result i32)
          (local $result i32)
          local.get $new-size
          i32.eqz
          if (result i32)
            i32.const 0
          else
            global.get $next
            local.set $result
            global.get $next
            local.get $new-size
            i32.add
            global.set $next
            local.get $result
          end)

        (func (export "discover") (result i32)
          i32.const 0
          i32.const 64
          i32.store
          i32.const 4
          i32.const 19
          i32.store
          i32.const 0)

        (func (export "prepare")
          (param i32 i32 i32 i32) (result i32)
          i32.const 0
          i32.const 96
          i32.store
          i32.const 4
          i32.const 2
          i32.store
          i32.const 0)
      )
      (core instance $guest (instantiate $guest))
      (func (export "discover") (result string)
        (canon lift (core func $guest "discover")
          (memory $guest "memory")))
      (func (export "prepare")
        (param "capability-id" string) (param "input" string) (result string)
        (canon lift (core func $guest "prepare")
          (memory $guest "memory")
          (realloc (func $guest "realloc"))))
    )
    """#

    private static let sceneQueryComponentWAT = #"""
    (component
      (type $query-interface (instance
        (export "query" (func (param "request" string) (result string)))
      ))
      (import (interface "guava:scene/query")
        (instance $scene-query (type $query-interface)))
      (alias export $scene-query "query" (func $query))

      (core module $libc
        (memory (export "memory") 1)
        (global $next (mut i32) (i32.const 4096))
        (func (export "realloc")
          (param $old i32) (param $old-size i32)
          (param $align i32) (param $new-size i32) (result i32)
          (local $result i32)
          local.get $new-size
          i32.eqz
          if (result i32)
            i32.const 0
          else
            global.get $next
            local.set $result
            global.get $next
            local.get $new-size
            i32.add
            global.set $next
            local.get $result
          end)
      )
      (core instance $libc (instantiate $libc))
      (core func $query-lower
        (canon lower (func $query)
          (memory $libc "memory")
          (realloc (func $libc "realloc"))))

      (core module $guest
        (import "libc" "memory" (memory 1))
        (import "host" "query" (func $query (param i32 i32 i32)))
        (data (i32.const 64) "{\22capabilities\22:[]}")
        (data (i32.const 128) "{\22operation\22:\22snapshot\22}")

        (func (export "discover") (result i32)
          i32.const 0
          i32.const 64
          i32.store
          i32.const 4
          i32.const 19
          i32.store
          i32.const 0)

        (func (export "prepare")
          (param i32 i32 i32 i32) (result i32)
          i32.const 128
          i32.const 24
          i32.const 0
          call $query
          i32.const 0)
      )
      (core instance $guest (instantiate $guest
        (with "libc" (instance $libc))
        (with "host" (instance (export "query" (func $query-lower))))
      ))
      (func (export "discover") (result string)
        (canon lift (core func $guest "discover")
          (memory $libc "memory")))
      (func (export "prepare")
        (param "capability-id" string) (param "input" string) (result string)
        (canon lift (core func $guest "prepare")
          (memory $libc "memory")
          (realloc (func $libc "realloc"))))
    )
    """#

    private static let infinitePrepareComponentWAT = #"""
    (component
      (core module $guest
        (memory (export "memory") 1)
        (global $next (mut i32) (i32.const 4096))
        (data (i32.const 64) "{\22capabilities\22:[]}")
        (func (export "realloc")
          (param i32 i32 i32 i32) (result i32)
          global.get $next)
        (func (export "discover") (result i32)
          i32.const 0
          i32.const 64
          i32.store
          i32.const 4
          i32.const 19
          i32.store
          i32.const 0)
        (func (export "prepare")
          (param i32 i32 i32 i32) (result i32)
          (loop $forever
            br $forever)
          unreachable)
      )
      (core instance $guest (instantiate $guest))
      (func (export "discover") (result string)
        (canon lift (core func $guest "discover")
          (memory $guest "memory")))
      (func (export "prepare")
        (param "capability-id" string) (param "input" string) (result string)
        (canon lift (core func $guest "prepare")
          (memory $guest "memory")
          (realloc (func $guest "realloc"))))
    )
    """#
#endif
}
