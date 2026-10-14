import Foundation
import Testing
import NIOEmbedded
@testable import GuavaUIAgentTransport

@Suite("Local agent transport")
struct TransportTests {
    @Test func loopbackBindingSupportsEphemeralPortsAndRestart() throws {
        let server = AgentLocalServer { $0 }
        try server.start()
        #expect(server.boundPort != nil && server.boundPort != 0)
        server.stop()
        #expect(server.boundPort == nil)
        try server.start()
        #expect(server.boundPort != nil)
        server.stop()
    }
    @Test func oversizedLinesCloseConnection() throws {
        let channel = EmbeddedChannel(handler: AgentLineHandler { $0 })
        var bytes = channel.allocator.buffer(capacity: 1_048_577)
        bytes.writeRepeatingByte(97, count: 1_048_577)
        _ = try channel.writeInbound(bytes)
        #expect(!channel.isActive)
        _ = try? channel.finish()
    }
}
