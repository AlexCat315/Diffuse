internal import NIOCore
internal import NIOWebSocket

final class WebSocketReceiver: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  private let inbox: WebSocketInbox
  private var message = ByteBuffer()

  init(inbox: WebSocketInbox) { self.inbox = inbox }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .text, .binary, .continuation:
      var payload = frame.unmaskedData
      message.writeBuffer(&payload)
      if frame.fin {
        inbox.enqueue(String(buffer: message))
        message.clear()
      }
    case .ping:
      let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
      context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
    case .connectionClose:
      inbox.close()
      context.close(promise: nil)
    case .pong:
      break
    default:
      inbox.close()
      context.close(promise: nil)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    inbox.close()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    inbox.close()
    context.close(promise: nil)
  }
}
