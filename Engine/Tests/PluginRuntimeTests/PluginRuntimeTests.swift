import CapabilityRuntime
import Foundation
@testable import PluginRuntime
#if canImport(PluginWasmtimeRuntime)
@testable import PluginWasmtimeRuntime
#endif
import Testing

@Suite("PluginRuntime security boundary")
struct PluginRuntimeTests {
    @Test("typed inputs distinguish numeric zero and one from booleans")
    func typedNumbersAreNotBooleans() throws {
        let type = WITValueType.record([
            WITRecordField(name: "enabled", type: .bool),
            WITRecordField(name: "count", type: .u16),
        ])
        for count in [0, 1] {
            let input = Data("{\"enabled\":true,\"count\":\(count)}".utf8)
            let encoded = try PluginTypedInputEncoder.encode(input, as: type)
            #expect(Array(encoded) == [0x47, 0x54, 0x56, 0x31, 1, UInt8(count), 0])
            #expect(throws: PluginTypedInputError.typeMismatch(path: "$.enabled", expected: "bool")) {
                try PluginTypedInputEncoder.encode(Data("{\"enabled\":\(count),\"count\":1}".utf8), as: type)
            }
        }
    }

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
        let length = UInt32(PluginHostFrameCodec.maximumFrameBytes + 1)
        var oversized = Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        oversized.append(Data(repeating: 0, count: 4))
        #expect(throws: PluginHostFrameError.frameTooLarge) {
            try PluginHostFrameCodec.decode(PluginHostRequest.self, from: oversized)
        }
    }

    @Test("WIT filesystem imports are denied even when not declared")
    func witDeniesAmbientWASI() {
        let wit = """
        package example:safe;
        interface capabilities {
          record inspect-input { enabled: bool }
          inspect: func(input: inspect-input) -> string;
        }
        world plugin {
          import wasi:filesystem/types;
          export capabilities;
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
        interface capabilities {
          record inspect-input { enabled: bool }
          inspect: func(input: inspect-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """
        let contract = try WITContractParser.parse(Data(wit.utf8), grantedImports: [])
        #expect(contract.worldName == "plugin")
        #expect(contract.exports.map(\.name) == ["example:safe/capabilities"])
        #expect(contract.capabilitiesInterfaceName == "example:safe/capabilities")
        #expect(contract.capabilityInputs.map(\.name) == ["inspect"])
        let versioned = try WITContractParser.parse(
            Data(wit.replacingOccurrences(of: "example:safe",
                                          with: "example:safe@1.2.3").utf8),
            grantedImports: []
        )
        #expect(versioned.capabilitiesInterfaceName ==
            "example:safe/capabilities@1.2.3")

        let loose = """
        package example:unsafe;
        interface capabilities {
          record inspect-input { enabled: bool }
          inspect: func(input: inspect-input) -> string;
        }
        world plugin {
          export discover: func() -> string;
        }
        """
        #expect(throws: WITContractError.malformedDeclaration(
            "plugin world must export exactly the capabilities interface"
        )) {
            try WITContractParser.parse(Data(loose.utf8), grantedImports: [])
        }

        let twoWorlds = wit + "\nworld second {}"
        #expect(throws: WITContractError.malformedDeclaration("exactly one world is required")) {
            try WITContractParser.parse(Data(twoWorlds.utf8), grantedImports: [])
        }
    }

    @Test("WIT records are the only source of strict capability schemas")
    func witDerivesCapabilitySchema() throws {
        let wit = """
        package example:safe;
        interface capabilities {
          /// World-space point used by inspection.
          record point {
            x: f32,
            y: f32,
            z: f32,
          }
          enum detail-level { summary, full }
          /// Inspect Scene Finds matching entities without changing the scene.
          record inspect-scene-input {
            /// Optional query text.
            query: option<string>,
            origin: point,
            detail: detail-level,
            tags: list<string>,
          }
          inspect-scene: func(input: inspect-scene-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """
        let parsed = try WITContractParser.parse(Data(wit.utf8), grantedImports: [])
        let input = try #require(parsed.capabilityInputs.first)
        #expect(input.name == "inspect-scene")
        #expect(input.title == "Inspect Scene")
        #expect(input.inputSchema.additionalProperties == false)
        #expect(input.inputSchema.required == ["detail", "origin", "tags"])
        #expect(input.inputSchema.properties["query"]?.oneOf.count == 2)
        #expect(input.inputSchema.properties["origin"]?.type == .object)
        #expect(input.inputSchema.properties["detail"]?.allowedValues == [
            .string("summary"), .string("full"),
        ])
        #expect(input.inputSchema.properties["tags"]?.maximumItems == 4_096)
        #expect(input.inputType.canonicalSignature ==
            "record{query:option<string>,origin:record{x:f32,y:f32,z:f32},detail:enum{summary,full},tags:list<string>}")

        let unsupported = wit.replacingOccurrences(of: "query: option<string>",
                                                   with: "query: u64")
        #expect(throws: WITContractError.unsupportedType("u64")) {
            try WITContractParser.parse(Data(unsupported.utf8), grantedImports: [])
        }
    }

    @Test("typed input encoding is deterministic and rejects shape drift")
    func typedInputEncodingIsStrict() throws {
        let type = WITValueType.record([
            WITRecordField(name: "enabled", type: .bool),
            WITRecordField(name: "count", type: .u16),
            WITRecordField(name: "label", type: .option(.string)),
            WITRecordField(name: "mode", type: .enumeration(["fast", "safe"])),
        ])
        let encoded = try PluginTypedInputEncoder.encode(
            Data(#"{"count":513,"enabled":true,"label":"ok","mode":"safe"}"#.utf8),
            as: type
        )
        #expect(Array(encoded.prefix(8)) == [0x47, 0x54, 0x56, 0x31,
                                             0x01, 0x01, 0x02, 0x01])
        #expect(Array(encoded.suffix(4)) == [0x01, 0x00, 0x00, 0x00])

        #expect(throws: PluginTypedInputError.missingField(path: "$.count")) {
            try PluginTypedInputEncoder.encode(
                Data(#"{"enabled":true,"mode":"fast"}"#.utf8),
                as: type
            )
        }
        #expect(throws: PluginTypedInputError.typeMismatch(
            path: "$", expected: "a strict WIT record"
        )) {
            try PluginTypedInputEncoder.encode(
                Data(#"{"count":1,"enabled":true,"forged":1,"mode":"fast"}"#.utf8),
                as: type
            )
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

    @Test("plugin writes require non-empty strict AI-exposed host primitives")
    func compositionRequiresSafeWritePrimitive() throws {
        let primitive = CapabilityDescriptor(
            verb: "scene.safe_rename",
            domain: "scene",
            version: 1,
            access: .reversibleWrite,
            inputSchema: .object(properties: ["name": .string()], required: ["name"]),
            source: .builtin,
            isAIExposed: true
        )
        let registry = CapabilityRegistry(capabilities: [primitive])
        let manifest = GuavaPluginManifest(
            id: "safe.layout",
            version: 1,
            name: "Layout",
            description: "Safe composition",
            access: .reversibleWrite,
            composableHostCapabilities: [primitive.verb]
        )
        #expect(throws: PluginCompositionError.emptyWriteComposition) {
            try PluginCompositionValidator.validate([], manifest: manifest, registry: registry)
        }
        let call = HostCapabilityCall(capabilityID: primitive.verb,
                                      version: primitive.version,
                                      arguments: Data(#"{"name":"Safe"}"#.utf8))
        #expect(try PluginCompositionValidator.validate([call],
                                                        manifest: manifest,
                                                        registry: registry) == [call])

        var unsafe = primitive
        unsafe.isAIExposed = false
        let unsafeRegistry = CapabilityRegistry(capabilities: [unsafe])
        #expect(throws: PluginManifestValidationError.unsafeHostPrimitive(primitive.verb)) {
            try PluginManifestValidator.validate(manifest, registry: unsafeRegistry)
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
        interface capabilities {
          record inspect-input { enabled: bool }
          inspect: func(input: inspect-input) -> string;
        }
        world plugin {
          export capabilities;
        }
        """
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))

        #expect(throws: PluginPackageError.invalidComponentHeader) {
            try PluginPackageLoader().load(at: root)
        }
    }

#if canImport(PluginWasmtimeRuntime)
    @Test("embedded Wasmtime validates and invokes the exact plugin ABI", arguments: [false, true])
    func embeddedRuntimeInvokesRealComponent(interpreter: Bool) throws {
        let package = try makePluginPackage(
            componentWAT: try Self.constantResultComponentWAT,
            imports: []
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime(useInterpreter: interpreter)

        try runtime.validateComponent(package, limits: .secureDefault)
        let prepared = try runtime.prepare(
            package,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"enabled":true}"#.utf8),
            querySnapshot: nil,
            limits: .secureDefault
        )

        #expect(runtime.usesInterpreter == interpreter)
        #expect(runtime.runtimeVersion == "49.0.2")
        #expect(String(decoding: prepared, as: UTF8.self) == "true")
        let disabled = try runtime.prepare(
            package,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"enabled":false}"#.utf8),
            querySnapshot: nil,
            limits: .secureDefault
        )
        #expect(String(decoding: disabled, as: UTF8.self) == "false")
    }

    @Test("mobile session binds approval and executes an immutable package copy")
    func embeddedSessionOwnsApprovedCode() async throws {
        let package = try makePluginPackage(componentWAT: try Self.constantResultComponentWAT, imports: [])
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let inspection = try await EmbeddedPluginSession.inspect(at: package.rootURL)
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        let session = try await EmbeddedPluginSession.open(at: package.rootURL, authorization: authorization)
        // Mutating the source cannot change an already opened session.
        try Data([0]).write(to: package.componentURL)
        let result = try await session.prepare(capabilityID: "safe.reader.inspect",
                                               input: Data(#"{"enabled":true}"#.utf8))
        #expect(result == .read(Data("true".utf8)))
        await #expect(throws: (any Error).self) {
            try await EmbeddedPluginSession.open(at: package.rootURL, authorization: authorization)
        }
    }

    @Test("isolated GuavaPluginHost loads and invokes a real Component over RPC")
    func pluginHostEndToEnd() throws {
        let package = try makePluginPackage(
            componentWAT: try Self.constantResultComponentWAT,
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
        #expect(handshakeJSON["protocol_version"] as? Int == 5)
        #expect(handshakeJSON["wasmtime_version"] as? String == "49.0.2")
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
        #expect(inspection.contracts.map(\.id) == ["safe.reader.inspect"])
        #expect(inspection.contracts[0].inputSchema.type == .object)
        #expect(inspection.contracts[0].inputSchema.properties["enabled"]?.type == .boolean)
        #expect(inspection.contracts[0].inputSchema.required == ["enabled"])
        #expect(inspection.contracts[0].inputSchema.additionalProperties == false)

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
        #expect(discovery.payload
            == Data(#"{"capability_ids":["safe.reader.inspect"]}"#.utf8))

        let invalidInput = try client.call(PluginHostRequest(
            method: .prepare,
            pluginPath: path,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"forged":true}"#.utf8),
            authorization: authorization
        ))
        #expect(!invalidInput.ok)

        let prepared = try client.call(PluginHostRequest(
            method: .prepare,
            pluginPath: path,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"enabled":true}"#.utf8),
            authorization: authorization
        ))
        #expect(prepared.ok)
        #expect(prepared.payload == Data("true".utf8))

        let inspectedAgain = try client.inspectPlugin(at: package.rootURL)
        #expect(inspectedAgain == inspection)
        let typedBinding = try client.loadPlugin(at: package.rootURL,
                                                 authorization: authorization)
        #expect(typedBinding.authority.hostGeneration == client.generation)
        let typedPrepared = try client.prepareCapability(
            binding: typedBinding,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"enabled":true}"#.utf8),
            querySnapshot: nil
        )
        #expect(typedPrepared == .read(Data("true".utf8)))

        let unloaded = try client.call(PluginHostRequest(method: .unload,
                                                         pluginPath: path))
        #expect(unloaded.ok)
        // Typed helper: a successful unload answers with an empty ok response
        // and must not throw for the missing payload.
        try client.unloadPlugin(at: package.rootURL)
        let loadedGeneration = client.generation
        client.stop()
        #expect(client.generation == loadedGeneration + 1)
        #expect(throws: PluginAuthorizationError.noLongerValid) {
            try typedBinding.validate(hostGeneration: client.generation)
        }
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

    @Test("plugin authorization binds code, WIT, permissions, and schemas")
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
                                     exports: [],
                                     capabilityInputs: [
                                         WITCapabilityInput(
                                            name: "inspect",
                                            title: "Inspect",
                                            description: "Returns bounded findings",
                                            inputSchema: .object(properties: [:]),
                                            inputType: .record([])
                                         ),
                                     ]),
            componentHash: "component-a",
            witHash: "wit-a"
        )
        let contract = try #require(PluginWITContractDeriver.contracts(for: package).first)
        let inspection = PluginInspection(
            package: package,
            contracts: PluginWITContractDeriver.contracts(for: package)
        )
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

    }

#if canImport(PluginWasmtimeRuntime)
    @Test("embedded Component can query only its granted revision-bound snapshot", arguments: [false, true])
    func embeddedRuntimeDispatchesGrantedQueryImport(interpreter: Bool) throws {
        let package = try makePluginPackage(
            componentWAT: try Self.sceneQueryComponentWAT,
            imports: [.sceneQuery]
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime(useInterpreter: interpreter)
        let scene = Data(#"{"entities":[{"id":"scene:1"}]}"#.utf8)
        let snapshot = PluginQuerySnapshot(sceneRevision: 17, scene: scene)

        try runtime.validateComponent(package, limits: .secureDefault)
        let prepared = try runtime.prepare(
            package,
            capabilityID: "safe.reader.inspect",
            input: Data(#"{"enabled":true}"#.utf8),
            querySnapshot: snapshot,
            limits: .secureDefault
        )

        #expect(prepared == scene)
        #expect(throws: PluginQuerySnapshotError.missingPayload(.sceneQuery)) {
            try runtime.prepare(
                package,
                capabilityID: "safe.reader.inspect",
                input: Data(#"{"enabled":true}"#.utf8),
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
            componentWAT: try Self.constantResultComponentWAT,
            imports: [.sceneQuery]
        )
        defer { try? FileManager.default.removeItem(at: package.rootURL) }
        let runtime = try EmbeddedWasmtimeComponentRuntime()

        #expect(throws: EmbeddedWasmtimeError.self) {
            try runtime.validateComponent(package, limits: .secureDefault)
        }
    }

    @Test("Component typed inputs must exactly match capabilities.wit")
    func embeddedRuntimeRejectsTypedInputDrift() throws {
        let package = try makePluginPackage(
            componentWAT: try Self.constantResultComponentWAT,
            imports: [],
            inputFields: "enabled: u32,"
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
            componentWAT: try Self.infinitePrepareComponentWAT,
            imports: [],
            capabilityName: "loop"
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
                input: Data(#"{"enabled":true}"#.utf8),
                querySnapshot: nil,
                limits: limits
            )
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
#endif

    @Test("Editor RPC client restarts a PluginHost that misses its deadline")
    func processClientDeadlineRestartsHost() throws {
        #if os(Windows)
        let executable = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["ComSpec"]
                ?? "C:\\Windows\\System32\\cmd.exe")
        // A built-in loop stays in the host process, matching exec sleep on
        // Unix; an external ping child would keep inherited pipes open.
        let launchArguments = ["/d", "/s", "/c", "for /l %n in (0,0,1) do @rem"]
        #else
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
        let launchArguments: [String] = []
        #endif
        let client = PluginHostProcessClient(executableURL: executable,
                                             launchArguments: launchArguments)
        defer { client.stop() }
        let clock = ContinuousClock()
        let start = clock.now

        #expect(throws: PluginHostClientError.hostRestarted(generation: 1)) {
            try client.call(PluginHostRequest(method: .handshake),
                            timeoutMilliseconds: 50)
        }
        #expect(client.generation == 1)
        #expect(start.duration(to: clock.now) < .seconds(1))
        // Exhausting the one immediate restart must not stop invalidation.
        #expect(throws: PluginHostClientError.hostRestarted(generation: 2)) {
            try client.call(PluginHostRequest(method: .handshake),
                            timeoutMilliseconds: 50)
        }
        #expect(client.generation == 2)
    }

#if canImport(PluginWasmtimeRuntime)
    /// Most recently built copy of the named executable. Multiple scratch
    /// directories can hold copies of the same product; a stale one must not
    /// win over the binary this test run just built.
    private func builtExecutable(named requestedName: String) -> URL? {
        #if os(Windows)
        let name = requestedName + ".exe"
        #else
        let name = requestedName
        #endif
        var candidates: Set<URL> = []
        let launchLocations = [
            URL(fileURLWithPath: CommandLine.arguments[0]),
            Bundle.main.executableURL,
        ].compactMap { $0 }
        for launchLocation in launchLocations {
            var directory = launchLocation.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    candidates.insert(candidate.resolvingSymlinksInPath())
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
                candidates.insert(candidate.resolvingSymlinksInPath())
            }
        }
        return candidates.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func makePluginPackage(componentWAT: String,
                                   imports: [PluginImportPermission],
                                   capabilityName: String = "inspect",
                                   inputFields: String = "enabled: bool,") throws -> ValidatedPluginPackage {
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
        interface capabilities {
          /// Execute one bounded capability.
          record \(capabilityName)-input {\(inputFields)}
          \(capabilityName): func(input: \(capabilityName)-input) -> string;
        }
        world plugin {
        \(importLines)
          export capabilities;
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

    private static var constantResultComponentWAT: String {
        get throws { try String(contentsOf: Bundle.module.url(forResource: "reader", withExtension: "wat", subdirectory: "Fixtures")!, encoding: .utf8) }
    }

    private static var sceneQueryComponentWAT: String {
        get throws { try String(contentsOf: Bundle.module.url(forResource: "scene-query", withExtension: "wat", subdirectory: "Fixtures")!, encoding: .utf8) }
    }

    private static var infinitePrepareComponentWAT: String {
        get throws { try String(contentsOf: Bundle.module.url(forResource: "infinite", withExtension: "wat", subdirectory: "Fixtures")!, encoding: .utf8) }
    }
#endif
}
