import Foundation
import PluginRuntime
import LanguageServerRuntime
import ProcessRuntime

final class PluginLanguageService: @unchecked Sendable {
    static let pluginID = "studio.swift-support"
    private let lock = NSLock()
    private var binding: PluginExecutionBinding?
    private var client: PluginHostProcessClient?

    var isBound: Bool { lock.withLock { binding != nil && client != nil } }
    private var memoryBytes: UInt64?
    var residentMemoryBytes: UInt64? { lock.withLock { memoryBytes } }

    @discardableResult
    func bind(_ binding: PluginExecutionBinding?, client: PluginHostProcessClient? = nil) -> Bool {
        lock.withLock {
            let changed = self.binding?.authority != binding?.authority || self.client !== client
            self.binding = binding; self.client = client
            memoryBytes = nil
            return changed
        }
    }

    func connect(_ command: ProcessCommand) throws -> LanguageServerTransport {
        let (binding, client) = try lock.withLock {
            guard let binding, let client else {
                throw ScriptLanguageSupportError.unavailable("Swift Support is disabled or unavailable.")
            }
            return (binding, client)
        }
        let invoke: @Sendable (PluginProcessRequest) throws -> PluginProcessUpdate = { request in
            let encoded = try JSONEncoder().encode(request)
            let input = try JSONEncoder().encode(["request": String(decoding: encoded, as: UTF8.self)])
            let result = try client.prepareCapability(binding: binding,
                capabilityID: binding.pluginID + ".language-server", input: input, querySnapshot: nil)
            guard case let .read(data) = result else { throw PluginProcessError.invalidRequest }
            return try JSONDecoder().decode(PluginProcessUpdate.self, from: data)
        }
        var start = PluginProcessRequest(.start)
        start.permission = "language-server"
        start.arguments = command.arguments
        let keys = Set(binding.authorization.host.processes.first { $0.id == start.permission }?.environmentKeys ?? [])
        start.environment = command.environment.filter { keys.contains($0.key) }
        let handle = try invoke(start).handle
        let (events, continuation) = AsyncThrowingStream<ProcessEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let poller = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    var poll = PluginProcessRequest(.poll); poll.handle = handle
                    let update = try invoke(poll)
                    self?.lock.withLock { self?.memoryBytes = update.residentMemoryBytes }
                    for event in [update.stdout.isEmpty ? nil : ProcessEvent.stdout(update.stdout),
                                  update.stderr.isEmpty ? nil : ProcessEvent.stderr(update.stderr)].compactMap({ $0 }) {
                        if case .dropped = continuation.yield(event) { throw ProcessRuntimeError.outputLimit }
                    }
                    if let failure = update.failure { throw ScriptLanguageSupportError.unavailable(failure) }
                    if let status = update.exitStatus {
                        continuation.yield(.exited(status))
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in poller.cancel() }
        return LanguageServerTransport(events: events, write: { data in
            var offset = 0
            while offset < data.count {
                let end = min(offset + 8192, data.count)
                var write = PluginProcessRequest(.write)
                write.handle = handle; write.input = data.subdata(in: offset..<end)
                _ = try invoke(write)
                offset = end
            }
        }, stop: {
            poller.cancel()
            var stop = PluginProcessRequest(.stop); stop.handle = handle
            _ = try? invoke(stop)
            continuation.finish()
        })
    }
}
