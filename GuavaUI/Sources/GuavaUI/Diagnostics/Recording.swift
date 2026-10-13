import GuavaUICompose
import GuavaUIRuntime
import GuavaUIDevTools

extension Application {
    func configureCheckpoint(_ tools: DevTools) {
        guard let checkpoint else { return }
        tools.checkpoint.capture = { checkpoint.capture() }
        tools.checkpoint.restore = { checkpoint.restore($0) }
        tools.recording.start = { [weak self] in
            guard let self, let session = host.mainSession, !recorder.isRecording else { return false }
            recorder.start(state: checkpoint.capture(),
                           focusTarget: session.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String)
            return true
        }
        tools.recording.stop = { [weak self] in self?.recorder.stop() }
        tools.recording.replay = { [weak self] recording in
            guard let self, !recorder.isRecording, recording.isValid,
                  let session = host.mainSession, checkpoint.restore(recording.initialState) else { return false }
            session.pointerCapture.release()
            session.withCurrent {
                session.recomposer.commitAll()
                composition.graph.computeLayoutIfNeeded(width: Float(session.logicalSize.width), height: Float(session.logicalSize.height))
                func find(_ node: Node, name: String) -> Node? {
                    if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
                    for child in node.children { if let found = find(child, name: name) { return found } }
                    return nil
                }
                session.focusChain.focus(recording.focusTarget.flatMap { name in composition.tree.root.flatMap { find($0, name: name) } })
                for input in recording.events {
                    session.injectEvent(input.event)
                    session.recomposer.commitAll()
                    composition.graph.computeLayoutIfNeeded(width: Float(session.logicalSize.width), height: Float(session.logicalSize.height))
                }
            }
            session.requestDisplay()
            return true
        }
    }
}
