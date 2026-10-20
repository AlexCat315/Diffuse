import Foundation
import CapabilityRuntime
@testable import PluginRuntime
import Testing

#if os(macOS) || os(Linux)
@Suite("Extension process authority", .timeLimit(.minutes(1)))
struct PluginProcessTests {
    private func inspection(_ id: String = "test.process") throws -> PluginInspection {
        var rule = PluginProcessPermission(id: "echo", command: "printf")
        rule.argumentPrefix = ["hello"]
        rule.entryPoints = ["launch"]
        var permissions = PluginHostPermissions(); permissions.processes = [rule]
        let manifest = GuavaPluginManifest(id: id, version: 1, name: "Process test", description: "fixture", access: .read,
                                          imports: [.process], host: permissions)
        let wit = try WITContractParser.parse(Data("""
        package test:process;
        interface capabilities {
          record launch-input { enabled: bool }
          launch: func(input: launch-input) -> string;
        }
        world plugin { import guava:process/host; export capabilities; }
        """.utf8), grantedImports: [.process])
        let package = ValidatedPluginPackage(rootURL: URL(fileURLWithPath: "/tmp/test.guavaplugin"), manifest: manifest,
            componentURL: URL(fileURLWithPath: "/tmp/component.wasm"), witURL: URL(fileURLWithPath: "/tmp/capabilities.wit"),
            witContract: wit, componentHash: "code", witHash: "contract")
        return PluginInspection(package: package, contracts: PluginWITContractDeriver.contracts(for: package))
    }
    private func mount(_ service: PluginProcessService, _ inspection: PluginInspection) throws {
        var context = PluginProcessContext(workspace: FileManager.default.temporaryDirectory)
        context.executables = ["printf": URL(fileURLWithPath: "/usr/bin/printf")]
        try service.mount(inspection: inspection, authorization: PluginAuthorizationRecord(inspection: inspection), context: context)
    }

    @Test("exact arguments, environment and host entry points are enforced")
    func permissions() throws {
        let service = PluginProcessService(), inspection = try inspection()
        try mount(service, inspection)
        defer { service.unmount(pluginID: inspection.manifest.id) }
        var request = PluginProcessRequest(.start); request.permission = "echo"; request.arguments = ["hello", "extra"]
        #expect(throws: PluginProcessError.argumentsDenied) { try service.perform(pluginID: inspection.manifest.id, entryPoint: "launch", request: request) }
        request.arguments = ["hello"]; request.environment = ["LD_PRELOAD": "untrusted"]
        #expect(throws: PluginProcessError.environmentDenied) { try service.perform(pluginID: inspection.manifest.id, entryPoint: "launch", request: request) }
        request.environment = [:]
        #expect(throws: PluginProcessError.notAuthorized) { try service.perform(pluginID: inspection.manifest.id, entryPoint: "read-scene", request: request) }
    }

    @Test("a running process survives individual calls and returns drained output")
    func lifecycle() async throws {
        let service = PluginProcessService(), inspection = try inspection()
        try mount(service, inspection)
        defer { service.unmount(pluginID: inspection.manifest.id) }
        var start = PluginProcessRequest(.start); start.permission = "echo"; start.arguments = ["hello"]
        let handle = try service.perform(pluginID: inspection.manifest.id, entryPoint: "launch", request: start).handle
        var poll = PluginProcessRequest(.poll); poll.handle = handle
        var output = Data(), status: Int32?
        for _ in 0..<100 {
            let update = try service.perform(pluginID: inspection.manifest.id, entryPoint: "launch", request: poll)
            output.append(update.stdout); status = update.exitStatus
            if status != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: output, as: UTF8.self) == "hello")
        #expect(status == 0)
    }

    @Test("another plugin and a later mount cannot reuse handles")
    func revocation() throws {
        let service = PluginProcessService(), first = try inspection(), second = try inspection("test.second")
        try mount(service, first); try mount(service, second)
        defer { service.unmount(pluginID: first.manifest.id); service.unmount(pluginID: second.manifest.id) }
        var start = PluginProcessRequest(.start); start.permission = "echo"; start.arguments = ["hello"]
        let handle = try service.perform(pluginID: first.manifest.id, entryPoint: "launch", request: start).handle
        var poll = PluginProcessRequest(.poll); poll.handle = handle
        #expect(throws: PluginProcessError.invalidHandle) { try service.perform(pluginID: second.manifest.id, entryPoint: "launch", request: poll) }
        try mount(service, first)
        #expect(throws: PluginProcessError.invalidHandle) { try service.perform(pluginID: first.manifest.id, entryPoint: "launch", request: poll) }
    }

    @Test("command authority changes invalidate authorization and host functions are not AI exposed")
    func authorization() throws {
        var inspection = try inspection()
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        let binding = try PluginExecutionBinding(pluginPath: "/tmp/test.guavaplugin", inspection: inspection,
                                                  authorization: authorization, hostGeneration: 1)
        let registry = try PluginCapabilityRegistryBuilder.build(base: .default, bindings: [binding])
        #expect(registry.descriptor(for: "test.process.launch")?.isAIExposed == false)
        inspection.manifest.host.processes[0].allowsAdditionalArguments = true
        #expect(!authorization.isStillValid(for: inspection))
        #expect(try PluginAuthorizationRecord(inspection: inspection).authorityDigest != authorization.authorityDigest)
    }
}
#endif
