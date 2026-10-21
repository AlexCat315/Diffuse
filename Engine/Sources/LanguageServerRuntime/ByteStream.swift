public import Foundation
public import ProcessRuntime

public struct LanguageServerTransport: Sendable {
    let events: AsyncThrowingStream<ProcessEvent, Error>
    let write: @Sendable (Data) throws -> Void
    let stop: @Sendable () -> Void

    public init(events: AsyncThrowingStream<ProcessEvent, Error>,
                write: @escaping @Sendable (Data) throws -> Void,
                stop: @escaping @Sendable () -> Void) {
        self.events = events
        self.write = write
        self.stop = stop
    }
}
