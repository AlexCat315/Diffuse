import Foundation
import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchRecording(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        switch env.type {
        case "input.record.start":
            guard recordingOwner == nil, host.recording.start != nil else {
                sendError(for: env, on: conn, code: "invalid_state", message: "Recording unavailable or already active"); return
            }
            recordingOwner = ObjectIdentifier(conn)
            runOnHostMain { [weak self] in
                guard let self else { return }
                if self.host.recording.start?() == true { self.sendOK(for: env, on: conn) }
                else {
                    self.queue.async { self.recordingOwner = nil }
                    self.sendError(for: env, on: conn, code: "invalid_state", message: "Host could not start recording")
                }
            }

        case "input.record.stop":
            guard recordingOwner == ObjectIdentifier(conn) else {
                sendError(for: env, on: conn, code: "invalid_state", message: "This connection does not own a recording"); return
            }
            recordingOwner = nil
            runOnHostMain { [weak self] in
                guard let self else { return }
                if let recording = self.host.recording.stop?() {
                    self.send(DevToolsEnvelope(type: "input.record.stop.ok", id: env.id, payload: DevToolsCodec.json(recording)), on: conn)
                } else { self.sendError(for: env, on: conn, code: "invalid_state", message: "No recording") }
            }

        case "input.replay":
            guard recordingOwner == nil, host.recording.replay != nil else {
                sendError(for: env, on: conn, code: "invalid_state", message: "Stop recording before replaying"); return
            }
            let recording = DevToolsCodec.decode(InputRecording.self, env.payload)!
            runOnHostMain { [weak self] in
                guard let self else { return }
                if self.host.recording.replay?(recording) == true { self.sendOK(for: env, on: conn) }
                else { self.sendError(for: env, on: conn, code: "bad_request", message: "Host rejected recording state") }
            }

        default: break
        }
    }
}
