InspectorModules.messages = function(context) {
function handleEnvelope(env) {
  if (context.observation.handleObservationEnvelope(env)) return;
  switch (env.type) {
    case "hello":
      context.session.connection.capabilities = new Set(env.payload?.capabilities ?? []);
      context.session.connection.host = env.payload?.host ?? null;
      context.connection.send("hello.ack");
      if (context.controls.hasCapability("tree")) context.connection.send("tree.subscribe");
      if (context.controls.hasCapability("log")) context.connection.send("log.subscribe");
      if (context.controls.hasCapability("timing")) context.connection.send("timing.subscribe");
      if (context.controls.hasCapability("state.observe")) context.connection.send("state.list");
      if (context.controls.hasCapability("timeline") && context.performance?.isAutoTraceEnabled()) {
        context.connection.send("timeline.subscribe");
      }
      context.performance?.setConnected(true);
      context.controls.setControls(true);
      context.logs.appendLog({
        level: "info",
        label: "host",
        message: `Connected to ${env.payload?.host?.appTitle ?? "GuavaUI"} (${env.payload?.protocol ?? "unknown protocol"})`,
      });
      break;
    case "tree.snapshot":
    case "tree.delta":
      context.session.tree.snapshot = env.payload ?? null;
      context.session.tree.tree = env.payload?.root ?? null;
      if (context.session.tree.treeRenderFrame == null) context.session.tree.treeRenderFrame = requestAnimationFrame(() => {
        context.session.tree.treeRenderFrame = null;
        if (context.session.tree.snapshot?.inspection) context.inspection.syncInspection(context.session.tree.snapshot.inspection);
        context.tree.syncSelection(); context.tree.renderTree(); context.runtime.renderRuntime(context.session.tree.snapshot);
        context.analysis.renderRecompositionTable(); context.observation.renderStateRegistry();
      });
      break;
    case "log.snapshot":
      context.logs.acceptSnapshot(env.payload);
      break;
    case "log.gap":
      context.logs.deliveryGap(env.payload);
      break;
    case "log.entry":
      context.logs.appendLog(env.payload);
      break;
    case "timing.frame":
      context.timing.renderTiming(env.payload);
      context.performance?.recordFrame(env.payload);
      break;
    case "state.checkpoint.ok":
      context.elements.checkpoint.stateSnapshot.value = JSON.stringify(env.payload ?? {}, null, 2);
      context.logs.appendLog({ level: "info", label: "state", message: "Checkpoint captured." });
      break;
    case "state.diff.ok":
      context.elements.checkpoint.stateDiff.className = "details";
      context.elements.checkpoint.stateDiff.textContent = JSON.stringify(env.payload, null, 2);
      break;
    case "input.record.start.ok":
      context.session.checkpoint.recording = true; context.controls.setControls(context.session.connection.connected);
      break;
    case "input.record.stop.ok":
      context.session.checkpoint.recording = false; context.controls.setControls(context.session.connection.connected);
      context.elements.checkpoint.inputRecording.value = JSON.stringify(env.payload, null, 2);
      break;
    case "input.replay.ok":
      context.logs.appendLog({level:"info", label:"input", message:"Replay completed from initial checkpoint."});
      break;
    case "state.restore.ok":
      context.logs.appendLog({ level: "info", label: "state", message: "Checkpoint restore requested." });
      break;
    case "mirror.frame":
      context.mirror.renderMirror(env.payload);
      break;
    case "mirror.stopped":
      context.mirror.setMirrorInactive(`Stopped: ${env.payload?.reason ?? "unknown"}`);
      context.logs.appendLog({ level: "info", label: "mirror", message: `Stopped: ${env.payload?.reason ?? "unknown"}` });
      break;
    case "mirror.start.ok":
      context.mirror.setMirrorWaiting();
      break;
    case "mirror.stop.ok":
      context.mirror.setMirrorInactive("Stopped.");
      break;
    default:
      if (env.type === "select.node.err") {
        context.session.tree.pendingSelectionId = null; context.inspection.syncInspection(context.session.tree.inspection);
      } else if (env.type === "select.node.ok" && !context.controls.hasCapability("inspect")) {
        context.session.tree.pendingSelectionId = null;
      }
      if (env.type?.startsWith("inspect.")) {
        if (env.type.endsWith(".ok")) context.inspection.syncInspection(env.payload);
        else if (env.type.endsWith(".err")) context.inspection.inspectionMessage(env.payload?.message ?? "Request failed", true);
      }
      if (env.type?.endsWith(".err")) {
        if (env.type.startsWith("mirror.")) {
          context.mirror.setMirrorInactive(env.payload?.message ?? "Mirror request failed.");
        }
        context.logs.appendLog({ level: "error", label: env.type, message: env.payload?.message ?? "Request failed" });
      }
      break;
  }
}


return { handleEnvelope };
};
