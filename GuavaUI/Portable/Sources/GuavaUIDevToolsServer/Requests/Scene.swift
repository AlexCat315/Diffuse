import GuavaLogging
import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchScene(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        guard let client = clients[ObjectIdentifier(conn)] else { return }
        switch env.type {
        case "hello.ack":
            // Nothing to do — capabilities negotiation is one-way for now.
            break

        case "tree.subscribe":
            setSubscription(.tree, enabled: true, for: conn)
            let epoch = generation
            runOnHostMain { [weak self] in
                guard let self, self.onQueueSync({ self.generation == epoch && self.isSubscribed(.tree, connection: conn) }) else { return }
                let snap = self.host.scene.snapshot?() ?? TreeSnapshotPayload(root: nil)
                self.encodeTree(snap, type: "tree.snapshot", id: env.id) { [weak self] data in
                    guard let self, let data else { return }
                    self.queue.async { [weak self] in
                        guard let self, self.generation == epoch,
                              self.isSubscribed(.tree, connection: conn) else { return }
                        conn.send(text: data)
                    }
                }
            }

        case "tree.unsubscribe":
            setSubscription(.tree, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        case "select.node":
            if let owner = inspectionOwner, owner != ObjectIdentifier(conn) {
                sendError(for: env, on: conn, code: "busy", message: "Another inspector owns the scene editor"); return
            }
            let nodeId = env.payload?.objectValue?["id"]?.stringValue
            if let nodeId {
                selectionOwner = ObjectIdentifier(conn)
                runOnHostMain { [weak self] in
                    guard let self, self.onQueueSync({ self.selectionOwner == ObjectIdentifier(conn) && self.clients[ObjectIdentifier(conn)] != nil }) else { return }
                    self.host.scene.select?(nodeId)
                    self.sendOK(for: env, on: conn)
                }
            } else {
                sendError(
                    for: env,
                    on: conn,
                    code: "bad_request",
                    message: "select.node requires payload.id"
                )
            }

        case "select.clear":
            let key = ObjectIdentifier(conn)
            if selectionOwner == key {
                selectionOwner = nil
                runOnHostMain { [weak self] in
                    guard let self, self.onQueueSync({ self.selectionOwner == nil }) else { return }
                    self.host.scene.clearSelection?()
                }
            }
            sendOK(for: env, on: conn)

        case "bye":
            conn.close()

        case "log.subscribe":
            client.session.logQuery = DevToolsCodec.decode(LogQuery.self, env.payload) ?? .init()
            let snapshot = DevToolsLogFeed.snapshot(client.session.logQuery)
            client.session.logSequence = snapshot.records.last?.sequence ?? client.session.logQuery.afterSequence ?? 0
            setSubscription(.log, enabled: true, for: conn)
            send(.init(type: "log.snapshot", id: env.id, payload: DevToolsCodec.json(snapshot)), on: conn)

        case "log.unsubscribe":
            setSubscription(.log, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        case "timing.subscribe":
            setSubscription(.timing, enabled: true, for: conn)
            sendOK(for: env, on: conn)

        case "timing.unsubscribe":
            setSubscription(.timing, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        default: break
        }
    }
}
