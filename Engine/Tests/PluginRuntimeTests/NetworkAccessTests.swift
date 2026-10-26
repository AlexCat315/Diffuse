import Foundation
@testable import PluginRuntime
import Testing

@Suite("Plugin network access")
struct PluginHTTPTests {
    private func manifest(_ host: String) -> Data {
        Data("""
        {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
         "imports": ["cove:http/host"], "composable_host_capabilities": [],
         "host": \(host), "contributes": {}}
        """.utf8)
    }

    @Test("a package must declare the hosts it may reach")
    func httpPermissionIsRequiredByImport() throws {
        let valid = try PluginManifestValidator.decodeAndValidate(manifest(
            #"{"http": [{"id": "api", "hosts": ["api.example.com"]}]}"#))
        #expect(valid.host.http.count == 1)
        #expect(valid.host.http[0].allows(host: "api.example.com"))
        #expect(!valid.host.http[0].allows(host: "evil.example.com"))
    }

    @Test("declaring network reach without the import, or the reverse, is rejected")
    func httpPermissionAndImportMustAgree() {
        #expect(throws: PluginManifestValidationError.invalidHostPermissions) {
            try PluginManifestValidator.decodeAndValidate(Data("""
            {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
             "imports": ["cove:http/host"], "composable_host_capabilities": [],
             "host": {"http": []}, "contributes": {}}
            """.utf8))
        }
        #expect(throws: PluginManifestValidationError.invalidHostPermissions) {
            try PluginManifestValidator.decodeAndValidate(Data("""
            {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
             "imports": [], "composable_host_capabilities": [],
             "host": {"http": [{"id": "api", "hosts": ["api.example.com"]}]}, "contributes": {}}
            """.utf8))
        }
    }

    @Test("host rules cannot smuggle a path, credentials or a port range")
    func httpHostPatternsAreBounded() {
        for invalid in [#"["https://api.example.com"]"#,
                        #"["user@api.example.com"]"#,
                        #"["api.example.com/v1"]"#,
                        #"["*"]"#,
                        #"[]"#] {
            #expect(throws: PluginManifestValidationError.invalidHostPermissions) {
                try PluginManifestValidator.decodeAndValidate(manifest(#"{"http": [{"id": "api", "hosts": \#(invalid)}]}"#))
            }
        }
        let wildcard = try? PluginManifestValidator.decodeAndValidate(manifest(
            #"{"http": [{"id": "api", "hosts": ["*.example.com"]}]}"#))
        #expect(wildcard?.host.http.first?.allows(host: "api.example.com") == true)
        #expect(wildcard?.host.http.first?.allows(host: "example.com") == false)
    }

    @Test("an agent contribution is validated")
    func agentContributionIsValidated() throws {
        func manifest(_ contributes: String) -> Data {
            Data("""
            {"id": "test.agent", "version": 1, "name": "Agent", "description": "fixture",
             "access": "read", "imports": [], "composable_host_capabilities": [],
             "contributes": \(contributes)}
            """.utf8)
        }
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "instructions": "Be brief.",
              "model": {"preferred": "claude-sonnet-4-6", "maxOutputTokens": 4096},
              "tools": ["read_file", "scene.set_name"], "context": ["scene", "git-summary"]}]}
            """))
        let agents = try valid.contributes.decode(AgentContributionPoint.self)
        #expect(agents.first?.model?.preferred == "claude-sonnet-4-6")
        #expect(agents.first?.context == ["scene", "git-summary"])

        for invalid in [#"{"cove.ai.agent/v1": [{"id": "Assistant", "title": "Assistant"}]}"#,
                        #"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "model": {"preferred": ""}}]}"#,
                        #"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "tools": ["Read File"]}]}"#,
                        #"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "context": ["scene", "scene"]}]}"#] {
            #expect(throws: PluginManifestValidationError.invalidContribution("cove.ai.agent/v1")) {
                try PluginManifestValidator.decodeAndValidate(manifest(invalid))
            }
        }
    }
}
