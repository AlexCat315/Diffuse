import CapabilityRuntime
import Foundation
@testable import PluginRuntime
import Testing

@Suite("Plugin authority and transport")
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
        let length = UInt32(PluginHostFrameCodec.maximumFrameBytes + 1)
        var oversized = Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        oversized.append(Data(repeating: 0, count: 4))
        #expect(throws: PluginHostFrameError.frameTooLarge) {
            try PluginHostFrameCodec.decode(PluginHostRequest.self, from: oversized)
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
        let manifest = CovePluginManifest(id: "safe.layout",
                                           version: 1,
                                           name: "Safe layout",
                                           description: "Layout helper",
                                           access: .reversibleWrite,
                                           composableHostCapabilities: [])
        #expect(throws: PluginCompositionError.capabilityNotGranted(contract.id)) {
            try PluginCompositionValidator.validate([call], manifest: manifest)
        }

        let understated = CovePluginManifest(
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
        let manifest = CovePluginManifest(
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
            rootURL: URL(fileURLWithPath: "/safe.reader.coveplugin"),
            manifest: CovePluginManifest(
                id: "safe.reader",
                version: 1,
                name: "Reader",
                description: "Read a bounded snapshot",
                access: .read,
                imports: [.sceneQuery]
            ),
            runtime: ValidatedPluginRuntime(entryURL: URL(fileURLWithPath: "/safe.reader.coveplugin/component.wasm"),
            contractURL: URL(fileURLWithPath: "/safe.reader.coveplugin/capabilities.wit"),
            contract: PluginContract(
                                     imports: ["cove:scene/query"],
                                     
                                     capabilityInputs: [
                                         PluginEntryContract(
                                            name: "inspect",
                                            title: "Inspect",
                                            description: "Returns bounded findings",
                                            inputSchema: .object(properties: [:]),
                                            inputType: .record([])
                                         ),
                                     ]),
            codeHash: "component-a",
            contractHash: "wit-a")
        )
        let contract = try #require(PluginContractDeriver.contracts(for: package).first)
        let inspection = PluginInspection(
            package: package,
            contracts: PluginContractDeriver.contracts(for: package)
        )
        let authorization = try PluginAuthorizationRecord(
            inspection: inspection,
            authorisedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(authorization.isStillValid(for: inspection))

        var changedCode = inspection
        changedCode.codeHash = "component-b"
        #expect(!authorization.isStillValid(for: changedCode))
        var changedWIT = inspection
        changedWIT.contractHash = "wit-b"
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

}
