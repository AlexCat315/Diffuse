import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchWindow(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        guard let request = decodePayload(WindowResizePayload.self, from: env.payload), request.isValid else {
            sendError(for: env, on: conn, code: "bad_request",
                      message: "window.resize requires payload.width and payload.height in 1...16384")
            return
        }
        runOnHostMain { [weak self] in
            guard let self else { return }
            let failure: String? = self.host.window.resize.map { $0(request) } ?? "Host cannot resize its window"
            if let failure {
                self.sendError(for: env, on: conn, code: "not_supported", message: failure)
            } else {
                self.sendOK(for: env, on: conn)
            }
        }
    }
}
