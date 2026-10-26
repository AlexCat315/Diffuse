import CapabilityRuntime
import Foundation
@testable import PluginRuntime
#if canImport(PluginWasmtimeRuntime)
@testable import PluginWasmtimeRuntime
#endif
import Testing

@Suite("Plugin component build and contributions")
struct ComponentBuildTests {
    private static let wit = """
    package test:echo;
    interface capabilities {
      record provider-input { request: string, stdout: string }
      provider: func(input: provider-input) -> string;
    }
    world plugin {
      import cove:process/host;
      export capabilities;
    }
    """

    private static func manifest(_ versionControl: String, processes: String = """
        {"processes": [{"id": "git", "command": "git", "argumentPrefix": [], "allowsAdditionalArguments": true, "environmentKeys": [], "entryPoints": ["provider"], "lifetimeMilliseconds": 60000}]}
        """) -> Data {
        Data("""
        {"id": "test.echo", "version": 1, "name": "Echo", "description": "fixture", "access": "read",
         "imports": ["cove:process/host"], "composable_host_capabilities": [], "host": \(processes),
         "contributes": {"cove.vcs/v1": [\(versionControl)]}}
        """.utf8)
    }

    @Test("a version control contribution names one marker, ignore file and provider process")
    func versionControlContributionsAreValidated() throws {
        let valid = #"{"id": "git", "title": "Git", "marker": ".git", "ignoreFile": ".gitignore"}"#
        let manifest = try PluginManifestValidator.decodeAndValidate(Self.manifest(valid))
        #expect(((try? manifest.contributes.decode(VersionControlContributionPoint.self)) ?? []).first == VersionControlContribution(id: "git", title: "Git", marker: ".git",
                                                                                 ignoreFile: ".gitignore"))
        for invalid in [#"{"id": "Git", "title": "Git", "marker": ".git", "ignoreFile": ".gitignore"}"#,
                        #"{"id": "git", "title": "Git", "marker": "../.git", "ignoreFile": ".gitignore"}"#,
                        #"{"id": "git", "title": " ", "marker": ".git", "ignoreFile": ".gitignore"}"#] {
            #expect(throws: PluginManifestValidationError.invalidContribution("cove.vcs/v1")) {
                try PluginManifestValidator.decodeAndValidate(Self.manifest(invalid))
            }
        }
        let otherEntryPoint = #"{"processes": [{"id": "git", "command": "git", "argumentPrefix": [], "allowsAdditionalArguments": true, "environmentKeys": [], "entryPoints": ["inspect"], "lifetimeMilliseconds": 60000}]}"#
        #expect(throws: PluginManifestValidationError.invalidContribution("cove.vcs/v1")) {
            try PluginManifestValidator.decodeAndValidate(Self.manifest(valid, processes: otherEntryPoint))
        }
    }

    @Test("tasks name one process and a marker; languages name extensions and an existing server process")
    func taskAndLanguageContributionsAreValidated() throws {
        func manifest(_ contributes: String) -> Data {
            Data("""
            {"id": "test.lang", "version": 1, "name": "Lang", "description": "fixture", "access": "read",
             "imports": ["cove:process/host"], "composable_host_capabilities": [],
             "host": {"processes": [
               {"id": "server", "command": "lsp", "argumentPrefix": [], "allowsAdditionalArguments": true, "environmentKeys": [], "entryPoints": ["language-server"], "lifetimeMilliseconds": null},
               {"id": "package", "command": "tool", "argumentPrefix": [], "allowsAdditionalArguments": true, "environmentKeys": [], "entryPoints": ["tasks"], "lifetimeMilliseconds": null}]},
             "contributes": \(contributes)}
            """.utf8)
        }
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"cove.tasks/v1": [{"id": "pkg", "title": "Package", "marker": "Package.swift"}],
             "cove.language/v1": [{"id": "swift", "title": "Swift", "extensions": ["swift"],
                            "server": {"process": "server", "initializationOptions": {"backgroundIndexing": true},
                                       "watchedFiles": ["Package.resolved"]}}]}
            """))
        #expect(((try? valid.contributes.decode(TaskContributionPoint.self)) ?? []).first == TaskContribution(id: "pkg", title: "Package", marker: "Package.swift"))
        #expect(((try? valid.contributes.decode(LanguageContributionPoint.self)) ?? []).first?.server?.initializationOptions == .object(["backgroundIndexing": .bool(true)]))
        #expect(throws: PluginManifestValidationError.invalidContribution("cove.tasks/v1")) {
            try PluginManifestValidator.decodeAndValidate(manifest(#"{"cove.tasks/v1": [{"id": "pkg", "title": "Package", "marker": "a/b"}]}"#))
        }
        for invalid in [#"{"cove.language/v1": [{"id": "swift", "title": "Swift", "extensions": []}]}"#,
                        #"{"cove.language/v1": [{"id": "swift", "title": "Swift", "extensions": [".swift"]}]}"#,
                        #"{"cove.language/v1": [{"id": "swift", "title": "Swift", "extensions": ["swift"], "server": {"process": "missing"}}]}"#] {
            #expect(throws: PluginManifestValidationError.invalidContribution("cove.language/v1")) {
                try PluginManifestValidator.decodeAndValidate(manifest(invalid))
            }
        }
    }

    @Test("the shell names every import and export the WIT contract implies")
    func shellAndBindings() throws {
        let contract = try WITContractParser.parse(Data(Self.wit.utf8), grantedImports: [.process])
        let shell = try PluginComponentBuild.shell(for: contract)
        #expect(shell.wat.contains(#"(import "cove:process/host" "query" (func (param i32 i32 i32)))"#))
        #expect(shell.wat.contains(#"(func (export "provider") (param i32 i32 i32 i32) (result i32) unreachable)"#))
        #expect(shell.bindings.contains("@_expose(wasm, \"provider\")"))
        #expect(shell.bindings.contains(
            "CanonicalABI.result(provider(request: CanonicalABI.string(p0, n0), stdout: CanonicalABI.string(p1, n1)))"))
        let unsupported = try WITContractParser.parse(Data(Self.wit.replacingOccurrences(of: "stdout: string", with: "stdout: bool").utf8),
                                                      grantedImports: [.process])
        #expect(throws: PluginComponentBuild.Error.unsupportedInput(capability: "provider")) {
            try PluginComponentBuild.shell(for: unsupported)
        }
    }

    #if canImport(PluginWasmtimeRuntime)
    @Test("a guest core module linked into the shell runs as the declared Component")
    func linkedGuestRuns() throws {
        let contract = try WITContractParser.parse(Data(Self.wit.utf8), grantedImports: [.process])
        let shell = try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(PluginComponentBuild.shell(for: contract).wat)
        // A guest that answers with its request.
        let core = try EmbeddedWasmtimeComponentRuntime.compileComponentWAT("""
        (module
          (import "cove:process/host" "query" (func (param i32 i32 i32)))
          (memory (export "memory") 16)
          (global $next (mut i32) (i32.const 1024))
          (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (local $address i32)
            (local.set $address (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
            (global.set $next (i32.add (local.get $address) (local.get 3)))
            local.get $address)
          (func (export "provider") (param i32 i32 i32 i32) (result i32)
            (i32.store (i32.const 0) (local.get 0))
            (i32.store (i32.const 4) (local.get 1))
            i32.const 0))
        """)
        #expect(throws: PluginComponentBuild.Error.invalidCoreModule) { try PluginComponentBuild.link(shell: shell, core: shell) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).coveplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginComponentBuild.link(shell: shell, core: core).write(to: root.appendingPathComponent("component.wasm"))
        try Data(Self.wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))
        try Self.manifest(#"{"id": "git", "title": "Git", "marker": ".git", "ignoreFile": ".gitignore"}"#)
            .write(to: root.appendingPathComponent("plugin.json"))
        let package = try PluginPackageLoader().load(at: root)
        let runtime = try EmbeddedWasmtimeComponentRuntime(processes: PluginProcessService())
        try runtime.validateComponent(package, limits: .secureDefault)
        let result = try runtime.prepare(package, capabilityID: "test.echo.provider",
                                         input: Data(#"{"request":"{\"op\":\"status\"}","stdout":"ab"}"#.utf8),
                                         querySnapshot: nil, limits: .secureDefault)
        #expect(String(decoding: result, as: UTF8.self) == #"{"op":"status"}"#)
        // An editor entry point takes whole tool output: no WIT length bound.
        let large = try JSONSerialization.data(withJSONObject: ["request": "{}", "stdout": String(repeating: "a", count: 300_000)])
        let echoed = try runtime.prepare(package, capabilityID: "test.echo.provider", input: large, querySnapshot: nil,
                                         limits: package.limits(for: "provider", default: .secureDefault))
        #expect(String(decoding: echoed, as: UTF8.self) == "{}")
    }
    #endif
}
