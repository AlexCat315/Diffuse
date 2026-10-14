import Foundation
import PluginRuntime
import PluginWasmtimeRuntime

@main
struct PluginRuntimeProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ProbeError.usage }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let inspection = try await EmbeddedPluginSession.inspect(at: url)
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        let session = try await EmbeddedPluginSession.open(at: url, authorization: authorization)
        let result = try await session.prepare(capabilityID: inspection.manifest.id + ".inspect",
                                              input: Data(#"{"enabled":true}"#.utf8))
        guard result == .read(Data("true".utf8)) else { throw ProbeError.invalidResult }
        print("PASS Swift EmbeddedPluginSession: approved package, typed input, JSON result")
    }
    enum ProbeError: Error { case usage, invalidResult }
}
