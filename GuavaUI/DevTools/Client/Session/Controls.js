InspectorModules.controls = function(context) {
function setControls(enabled) {
  context.inspection.inspectionControls();
  context.observation.observationControls();
  context.elements.connection.connect.disabled = enabled;
  context.elements.connection.disconnect.disabled = !enabled;
  context.elements.tree.refreshTree.disabled = !enabled || !hasCapability("tree");
  context.elements.mirror.startMirror.disabled = !enabled || !hasCapability("mirror") || context.session.mirror.mirrorActive;
  context.elements.mirror.stopMirror.disabled = !enabled || !hasCapability("mirror") || !context.session.mirror.mirrorActive;
  context.elements.checkpoint.captureState.disabled = !enabled || !hasCapability("state");
  context.elements.checkpoint.restoreState.disabled = !enabled || !hasCapability("state");
  context.elements.checkpoint.diffState.disabled = !enabled || !hasCapability("state");
  context.elements.checkpoint.recordInput.disabled = !enabled || !hasCapability("recording") || context.session.checkpoint.recording;
  context.elements.checkpoint.stopRecording.disabled = !enabled || !hasCapability("recording") || !context.session.checkpoint.recording;
  context.elements.checkpoint.replayInput.disabled = !enabled || !hasCapability("recording") || context.session.checkpoint.recording;
}

function setStatus(text, connected) {
  context.elements.connection.status.textContent = text;
  context.elements.connection.status.className = `status ${connected ? "connected" : "disconnected"}`;
}

function hasCapability(name) {
  return context.session.connection.capabilities.has(name);
}

function clearSessionViews() {
  if (context.session.tree.treeRenderFrame != null) cancelAnimationFrame(context.session.tree.treeRenderFrame);
  context.session.tree.treeRenderFrame = null;
  context.observation.resetObservations();
  context.session.checkpoint.recording = false;
  context.session.tree.tree = null;
  context.session.tree.snapshot = null;
  context.session.tree.selectedId = null;
  context.session.tree.inspection = null;
  context.session.tree.pendingSelectionId = null;
  context.analysis.renderRecompositionTable();
  context.session.timing.timingFrames = [];
  context.elements.tree.treeCount.textContent = "";
  context.elements.tree.tree.className = "tree empty";
  context.elements.tree.tree.textContent = "Connect to a GuavaUI app to inspect the live node tree.";
  context.tree.renderDetails(null);
  context.runtime.renderRuntime(null);
  context.elements.timing.timing.className = "details empty";
  context.elements.timing.timing.textContent = "No timing sample.";
}


return { setControls, setStatus, hasCapability, clearSessionViews };
};
