import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchObservation(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        guard let client = clients[ObjectIdentifier(conn)] else { return }
        switch env.type {
        case "state.list", "state.subscribe":
            guard host.observation.state != nil else {
                sendError(for: env, on: conn, code: "unsupported", message: "Host has no state registry"); return
            }
            let ids = env.type == "state.subscribe" ? DevToolsCodec.decode(StateWatchPayload.self, env.payload)!.ids : []
            if env.type == "state.subscribe" {
                client.session.watchedStateIDs = ids
                setSubscription(.state, enabled: true, for: conn)
            }
            runOnHostMain { [weak self] in
                guard let self, self.onQueueSync({ self.clients[ObjectIdentifier(conn)] != nil }),
                      let snapshot = self.host.observation.state?(ids) else { return }
                self.send(DevToolsEnvelope(type: env.type + ".ok", id: env.id, payload: encodeJSON(snapshot)), on: conn)
            }
        case "state.unsubscribe":
            client.session.watchedStateIDs = []
            setSubscription(.state, enabled: false, for: conn)
            sendOK(for: env, on: conn)
        case "timeline.subscribe":
            guard host.observation.timeline != nil, host.observation.capture != nil else {
                sendError(for: env, on: conn, code: "unsupported", message: "Host has no timeline recorder"); return
            }
            client.session.timelineSequence = 0
            setSubscription(.timeline, enabled: true, for: conn)
            runOnHostMain { [weak self] in
                guard let self else { return }
                self.syncTimelineCapture()
                guard let snapshot = self.host.observation.timeline?(0) else { return }
                self.queue.async { self.sendTimeline(snapshot, to: conn, id: env.id) }
            }
        case "timeline.unsubscribe":
            setSubscription(.timeline, enabled: false, for: conn)
            runOnHostMain { [weak self] in self?.syncTimelineCapture() }
            sendOK(for: env, on: conn)
        default: break
        }
    }
}
