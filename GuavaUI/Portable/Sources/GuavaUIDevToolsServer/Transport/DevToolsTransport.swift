import Foundation

/// Connection identity stays stable until the transport reports disconnection.
public protocol DevToolsConnection: AnyObject, Sendable {
    func send(text: Data)
    func close()
}

public enum DevToolsTransportEvent: Sendable {
    case connected(any DevToolsConnection)
    case text(any DevToolsConnection, Data)
    case disconnected(any DevToolsConnection)
}

/// Socket-independent boundary for protocol dispatch and future browser hosts.
/// Implementations must deliver connection events in order and release resources
/// on stop. DevServer serializes callbacks before changing subscription state.
public protocol DevToolsTransport: AnyObject, Sendable {
    var boundPort: UInt16? { get }
    func start(host: String, port: UInt16,
               onEvent: @escaping @Sendable (DevToolsTransportEvent) -> Void) throws
    func stop()
}
