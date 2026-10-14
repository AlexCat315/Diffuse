import Foundation
import NIOCore
import NIOPosix

/// Loopback JSON-lines transport for MCP or a host's private tool adapter.
/// The handler receives bytes; protocol and application data stay outside it.
public final class AgentLocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data?
    private let port: UInt16
    private let handler: Handler
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private let connections = AgentConnections()

    public var boundPort: UInt16? { lock.withLock { listener?.localAddress?.port.flatMap(UInt16.init(exactly:)) } }
    public init(port: UInt16 = 0, handle: @escaping Handler) { self.port = port; self.handler = handle }

    public func start() throws {
        try lock.withLock {
            guard listener == nil else { return }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let connections = self.connections, handler = self.handler
            do {
                let channel = try ServerBootstrap(group: group).childChannelInitializer { channel in
                    connections.insert(channel)
                    return channel.pipeline.addHandler(AgentLineHandler(handle: handler, onClose: { connections.remove(channel) }))
                }.bind(host: "127.0.0.1", port: Int(port)).wait()
                self.group = group; self.listener = channel
            } catch {
                try? group.syncShutdownGracefully()
                throw error
            }
        }
    }

    public func stop() {
        lock.withLock {
            try? listener?.close().wait()
            connections.closeAll()
            try? group?.syncShutdownGracefully()
            listener = nil; group = nil
        }
    }
}

private final class AgentConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    func insert(_ channel: Channel) { lock.withLock { channels[ObjectIdentifier(channel)] = channel } }
    func remove(_ channel: Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func closeAll() {
        let current = lock.withLock { let current = Array(channels.values); channels.removeAll(); return current }
        for channel in current { try? channel.close().wait() }
    }
}

// Buffers and request ordering are accessed exclusively on the channel event loop.
final class AgentLineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let handle: AgentLocalServer.Handler
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var task: Task<Void, Never>?
    init(handle: @escaping AgentLocalServer.Handler, onClose: @escaping @Sendable () -> Void = {}) {
        self.handle = handle; self.onClose = onClose
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        buffer.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard line.count <= 1_048_576 else { context.close(promise: nil); return }
            pending.append(line); pendingBytes += line.count
        }
        guard buffer.count <= 1_048_576, pending.count <= 64, pendingBytes <= 2_097_152 else { context.close(promise: nil); return }
        process(on: context.channel)
    }
    private func process(on channel: Channel) {
        guard task == nil, !pending.isEmpty, channel.isActive, channel.isWritable else { return }
        let input = pending.removeFirst(); pendingBytes -= input.count
        let handle = self.handle
        task = Task { [weak self] in
            let output = await handle(input)
            guard !Task.isCancelled else { return }
            channel.eventLoop.execute { [weak self] in
                guard let self, channel.isActive else { return }
                if let output {
                    guard output.count <= 2_097_152 else { _ = channel.close(); return }
                    var bytes = channel.allocator.buffer(capacity: output.count + 1)
                    bytes.writeBytes(output); bytes.writeInteger(UInt8(10))
                    channel.writeAndFlush(bytes, promise: nil)
                }
                self.task = nil
                self.process(on: channel)
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel(); task = nil; pending.removeAll(); buffer.removeAll(); pendingBytes = 0
        onClose(); context.fireChannelInactive()
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        process(on: context.channel)
        context.fireChannelWritabilityChanged()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
