import GuavaPluginKit

/// Tools this harness never lets the model run.
let blocked = ["export_project", "set_playback_state"]

/// Looks first, then lets the model act: the first model call is told to
/// inspect before drafting, and export or playback requests go back to the
/// model as refusals. Everything else runs exactly as the host's own loop would.
func harness(turn: String) -> String {
    guard let turn = HarnessTurn(turn) else { return HarnessStep.finish(summary: "The editor sent a malformed turn.") }
    switch turn.observation {
    case nil:
        return HarnessStep.model(
            instructions: "Start by inspecting the scene or project with a read-only tool; do not draft changes yet.")
    case let .model(call):
        if blocked.contains(call.name) {
            return HarnessStep.model(message: "This agent does not export or start playback. Finish with respond or submit_plan.")
        }
        return HarnessStep.tool(call)
    case .tool, .failure:
        return HarnessStep.model()
    }
}
