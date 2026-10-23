import Foundation
@testable import PluginRuntime
import Testing

@Suite("Plugin network access")
struct PluginHTTPTests {
    private func manifest(_ host: String) -> Data {
        Data("""
        {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
         "imports": ["guava:http/host"], "composable_host_capabilities": [],
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
             "imports": ["guava:http/host"], "composable_host_capabilities": [],
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

    @Test("an agent contribution names panels the workbench can render")
    func agentContributionIsValidated() throws {
        func manifest(_ contributes: String) -> Data {
            Data("""
            {"id": "test.agent", "version": 1, "name": "Agent", "description": "fixture",
             "access": "read", "imports": [], "composable_host_capabilities": [],
             "contributes": \(contributes)}
            """.utf8)
        }
        let valid = try PluginManifestValidator.decodeAndValidate(manifest("""
            {"guava.agent/v1": [{"id": "assistant", "title": "Assistant",
              "panels": [{"id": "intent-input", "title": "Harness", "slot": "trailing", "icon": "ai-intent"}]}]}
            """))
        let agents = try valid.contributes.decode(AgentContributionPoint.self)
        #expect(agents.first?.panels.first?.id == "intent-input")

        for invalid in [#"{"guava.agent/v1": [{"id": "assistant", "title": "Assistant", "panels": [{"id": "x", "title": "X", "slot": "middle"}]}]}"#,
                        #"{"guava.agent/v1": [{"id": "assistant", "title": "Assistant", "panels": [{"id": "x", "title": "X"}, {"id": "x", "title": "Y"}]}]}"#] {
            #expect(throws: PluginManifestValidationError.invalidContribution("guava.agent/v1")) {
                try PluginManifestValidator.decodeAndValidate(manifest(invalid))
            }
        }
    }
}
