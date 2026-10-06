import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// Desktop WebSocket transport for macOS, Linux and Windows. NIO handles the
/// HTTP upgrade and RFC 6455 framing; no platform-specific socket code is needed.
public final class NIODevToolsTransport: DevToolsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?

    public var boundPort: UInt16? {
        lock.withLock { listener?.localAddress?.port.flatMap(UInt16.init(exactly:)) }
    }

    public init() {}

    public func start(host: String, port: UInt16,
                      onEvent: @escaping @Sendable (DevToolsTransportEvent) -> Void) throws {
        let address: String
        switch host {
        case "localhost", "127.0.0.1": address = "127.0.0.1"
        case "::1", "0.0.0.0", "::": address = host
        case "*": address = "0.0.0.0"
        default: throw DevServerConfigurationError.unsupportedHost(host)
        }
        try lock.withLock {
            guard listener == nil else { return }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            do {
                let bootstrap = ServerBootstrap(group: group)
                #if !os(Windows)
                // Windows SO_REUSEADDR permits a second listener to take over
                // the same address. Keep its default exclusive binding instead.
                _ = bootstrap.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                #endif
                let channel = try bootstrap
                    .childChannelOption(ChannelOptions.writeBufferWaterMark,
                                        value: WriteBufferWaterMark(low: 256 * 1024, high: 4 * 1024 * 1024))
                    .childChannelInitializer { channel in
                        let upgrader = NIOWebSocketServerUpgrader(
                            maxFrameSize: DevToolsWebSocketHandler.maximumMessageBytes,
                            shouldUpgrade: { channel, request in
                                channel.eventLoop.makeSucceededFuture(
                                    request.uri == "/" ? HTTPHeaders() : nil)
                            },
                            upgradePipelineHandler: { channel, _ in
                                channel.pipeline.addHandler(DevToolsWebSocketHandler(onEvent: onEvent))
                            }
                        )
                        return channel.pipeline.configureHTTPServerPipeline(
                            withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                    }
                    .bind(host: address, port: Int(port)).wait()
                self.group = group
                self.listener = channel
            } catch {
                try? group.syncShutdownGracefully()
                throw error
            }
        }
    }

    public func stop() {
        let resources = lock.withLock { () -> (Channel?, MultiThreadedEventLoopGroup?) in
            defer { listener = nil; group = nil }
            return (listener, group)
        }
        try? resources.0?.close().wait()
        try? resources.1?.syncShutdownGracefully()
    }

    deinit { stop() }
}

private final class NIODevToolsConnection: DevToolsConnection, @unchecked Sendable {
    let channel: Channel
    init(channel: Channel) { self.channel = channel }

    func send(text: Data) {
        channel.eventLoop.execute { [channel] in
            guard channel.isActive else { return }
            // A stalled mirror client must not accumulate unbounded GPU frames.
            guard channel.isWritable else { _ = channel.close(); return }
            var buffer = channel.allocator.buffer(capacity: text.count)
            buffer.writeBytes(text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(frame).whenFailure { _ in _ = channel.close() }
        }
    }

    func close() { _ = channel.close() }
}

/// State is confined to the channel's event loop. Fragmented messages are
/// reassembled with a total limit, including when pings interrupt the fragments.
final class DevToolsWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    static let maximumMessageBytes = 1024 * 1024
    private let onEvent: @Sendable (DevToolsTransportEvent) -> Void
    private var connection: NIODevToolsConnection?
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments = Data()

    init(onEvent: @escaping @Sendable (DevToolsTransportEvent) -> Void) { self.onEvent = onEvent }

    func handlerAdded(context: ChannelHandlerContext) {
        let connection = NIODevToolsConnection(channel: context.channel)
        self.connection = connection
        onEvent(.connected(connection))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let connection { onEvent(.disconnected(connection)); self.connection = nil }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        // Clients must mask every frame. NIO decodes the mask; we enforce the
        // server-side requirement because its decoder also supports clients.
        guard frame.maskKey != nil else { fail(context, code: 1002); return }
        switch frame.opcode {
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong: break
        case .connectionClose:
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                _ = context.channel.close()
            }
        case .text, .binary:
            guard fragmentOpcode == nil else { fail(context, code: 1002); return }
            fragmentOpcode = frame.opcode
            append(frame, context: context)
        case .continuation:
            guard fragmentOpcode != nil else { fail(context, code: 1002); return }
            append(frame, context: context)
        default: fail(context, code: 1002)
        }
    }

    private func append(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let data = frame.unmaskedData
        guard fragments.count + data.readableBytes <= Self.maximumMessageBytes else {
            fail(context, code: 1009); return
        }
        fragments.append(contentsOf: data.readableBytesView)
        guard frame.fin else { return }
        defer { fragmentOpcode = nil; fragments.removeAll(keepingCapacity: true) }
        guard fragmentOpcode == .text else { return }
        guard String(data: fragments, encoding: .utf8) != nil else { fail(context, code: 1007); return }
        if let connection { onEvent(.text(connection, fragments)) }
    }

    private func fail(_ context: ChannelHandlerContext, code: UInt16) {
        var data = context.channel.allocator.buffer(capacity: 2)
        data.writeInteger(code)
        let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in _ = context.channel.close() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
