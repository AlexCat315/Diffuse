public import GuavaUIDevToolsProtocol

extension DevServer {
    func dispatchDiagnostics(_ request: DevToolsEnvelope, on connection: any DevToolsConnection) {
        guard host.scene.diagnostics != nil else {
            sendError(for: request, on: connection, code: "unsupported", message: "Host has no diagnostic query adapter")
            return
        }
        // Reads do not acquire or mutate the inspector's editing lease.
        let epoch = generation
        runOnHostMain { [weak self] in
            guard let self, self.onQueueSync({ self.generation == epoch && self.clients[ObjectIdentifier(connection)] != nil }),
                  let response = self.host.scene.diagnostics?(request) else { return }
            self.send(response, on: connection)
        }
    }
}
