import CapabilityRuntime
import Foundation
@testable import PluginRuntime
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
}
