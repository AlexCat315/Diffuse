import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchMirror(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        switch env.type {
        case "mirror.start":
            let payload: MirrorStartPayload
            if let rawPayload = env.payload {
                guard let decoded = decodePayload(MirrorStartPayload.self, from: rawPayload) else {
                    sendError(for: env, on: conn,
                              code: "bad_request",
                              message: "mirror.start payload is malformed")
                    return
                }
                payload = decoded
            } else {
                payload = MirrorStartPayload(fps: nil, quality: nil)
            }
            setSubscription(.mirror, enabled: true, for: conn)
            logger.debug("recv mirror.start fps=\(payload.fps ?? -1) quality=\(payload.quality ?? -1)")
            runOnHostMain { [weak self] in
                self?.host.mirror.start?(payload)
            }
            sendOK(for: env, on: conn)

        case "mirror.stop":
            let shouldStopCapture = setSubscription(.mirror, enabled: false, for: conn)
                && !hasSubscribers(for: .mirror)
            logger.debug("recv mirror.stop handlerWired=\(host.mirror.stop != nil) stopCapture=\(shouldStopCapture)")
            if shouldStopCapture {
                runOnHostMain { [weak self] in
                    self?.host.mirror.stop?()
                }
            }
            sendOK(for: env, on: conn)

        case "mirror.input":
            guard isSubscribed(.mirror, connection: conn) else {
                sendError(for: env, on: conn,
                          code: "invalid_state",
                          message: "mirror.input requires an active mirror subscription")
                return
            }
            if let input = decodePayload(MirrorInputPayload.self, from: env.payload) {
                runOnHostMain { [weak self] in
                    self?.host.mirror.input?(input)
                }
                sendOK(for: env, on: conn)
            } else {
                sendError(for: env, on: conn,
                          code: "bad_request",
                          message: "mirror.input requires payload")
            }

        default: break
        }
    }
}
