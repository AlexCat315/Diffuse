import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchCheckpoint(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        switch env.type {
        case "state.checkpoint":
            runOnHostMain { [weak self] in
                guard let self else { return }
                let snapshot = self.host.checkpoint.capture?() ?? [:]
                let response = DevToolsEnvelope(
                    type: "state.checkpoint.ok",
                    id: env.id,
                    payload: encodeJSON(snapshot)
                )
                self.send(response, on: conn)
            }

        case "state.restore":
            guard let object = env.payload?.objectValue,
                  object.values.allSatisfy({ $0.stringValue != nil }) else {
                sendError(for: env, on: conn,
                          code: "bad_request",
                          message: "state.restore requires an object with string values")
                return
            }
            let snapshot = object.compactMapValues(\.stringValue)
            runOnHostMain { [weak self] in
                guard let self else { return }
                if let restore = self.host.checkpoint.restore {
                    if restore(snapshot) { self.sendOK(for: env, on: conn) }
                    else { self.sendError(for: env, on: conn, code: "bad_request", message: "Host rejected checkpoint state") }
                } else { self.sendError(for: env, on: conn, code: "unsupported", message: "Host has no checkpoint restore provider") }
            }

        case "state.diff":
            let before = DevToolsSession.state(env.payload)!
            runOnHostMain { [weak self] in
                guard let self else { return }
                let diff = StateDifference(before: before, after: self.host.checkpoint.capture?() ?? [:])
                self.send(DevToolsEnvelope(type: "state.diff.ok", id: env.id, payload: DevToolsCodec.json(diff)), on: conn)
            }

        default: break
        }
    }
}
