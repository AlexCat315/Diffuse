import Foundation
import CapabilityRuntime
import PluginRuntime
#if canImport(PluginWasmtimeRuntime)
@testable import PluginWasmtimeRuntime
import Testing

#if os(macOS) || os(Linux)
@Suite("WASM process import")
struct ProcessGuestTests {
    @Test("a real Component starts a host-owned process without WASI")
    func invoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("process-\(UUID()).coveplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = #"{"operation":"start","permission":"echo","arguments":["hello"],"environment":{}}"#
        let fixture = try #require(Bundle.module.url(forResource: "scene-query", withExtension: "wat", subdirectory: "Fixtures"))
        var wat = try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "cove:scene/query", with: "cove:process/host")
        wat = wat.replacingOccurrences(of: #"{\22operation\22:\22snapshot\22}"#, with: request.replacingOccurrences(of: "\"", with: "\\22"))
            .replacingOccurrences(of: "i32.const 24\n", with: "i32.const \(request.utf8.count)\n")
        try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(wat).write(to: root.appendingPathComponent("component.wasm"))
        let wit = """
        package safe:reader;
        interface capabilities {
          record inspect-input { enabled: bool }
          inspect: func(input: inspect-input) -> string;
        }
        world plugin { import cove:process/host; export capabilities; }
        """
        try Data(wit.utf8).write(to: root.appendingPathComponent("capabilities.wit"))
        var rule = PluginProcessPermission(id: "echo", command: "printf")
        rule.argumentPrefix = ["hello"]; rule.entryPoints = ["inspect"]
        var permissions = PluginHostPermissions(); permissions.processes = [rule]
        let manifest = CovePluginManifest(id: "test.process-guest", version: 1, name: "Process", description: "fixture",
                                          access: .read, imports: [.process], host: permissions)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("plugin.json"))
        let package = try PluginPackageLoader().load(at: root)
        let inspection = PluginInspection(package: package, contracts: PluginWITContractDeriver.contracts(for: package))
        let service = PluginProcessService()
        var context = PluginProcessContext(workspace: FileManager.default.temporaryDirectory)
        context.executables = ["printf": URL(fileURLWithPath: "/usr/bin/printf")]
        try service.mount(inspection: inspection, authorization: PluginAuthorizationRecord(inspection: inspection), context: context)
        defer { service.unmount(pluginID: manifest.id) }
        let runtime = try EmbeddedWasmtimeComponentRuntime(processes: service)
        try runtime.validateComponent(package, limits: .secureDefault)
        let result = try runtime.prepare(package, capabilityID: "test.process-guest.inspect",
                                         input: Data(#"{"enabled":true}"#.utf8), querySnapshot: nil, limits: .secureDefault)
        let started = try JSONDecoder().decode(PluginProcessUpdate.self, from: result)
        var poll = PluginProcessRequest(.poll); poll.handle = started.handle
        var output = Data(), status: Int32?
        for _ in 0..<100 {
            let update = try service.perform(pluginID: manifest.id, entryPoint: "inspect", request: poll)
            output.append(update.stdout); status = update.exitStatus
            if status != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(status == 0)
        #expect(String(decoding: output, as: UTF8.self) == "hello")
    }
}
#endif
#endif
