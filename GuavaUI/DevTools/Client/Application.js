const inspector = (() => {
const context = { session, elements };
context.connection = InspectorModules.connection(context);
context.messages = InspectorModules.messages(context);
context.format = InspectorModules.format(context);
context.controls = InspectorModules.controls(context);
context.tree = InspectorModules.tree(context);
context.runtime = InspectorModules.runtime(context);
context.timing = InspectorModules.timing(context);
context.logs = InspectorModules.logs(context);
context.mirror = InspectorModules.mirror(context);
context.input = InspectorModules.input(context);
context.checkpoint = InspectorModules.checkpoint(context);
context.inspection = InspectorModules.inspection(context);
context.analysis = InspectorModules.analysis(context);
context.observation = InspectorModules.observation(context);
context.elements.connection.connect.addEventListener("click", context.connection.connect);
context.elements.connection.disconnect.addEventListener("click", context.connection.disconnect);
context.elements.tree.refreshTree.addEventListener("click", () => context.connection.send("tree.subscribe"));
context.elements.tree.treeSearch.addEventListener("input", () => {
  context.session.tree.treeQuery = context.elements.tree.treeSearch.value.trim().toLocaleLowerCase();
  context.tree.renderTree();
});
context.elements.mirror.startMirror.addEventListener("click", context.mirror.startMirror);
context.elements.mirror.stopMirror.addEventListener("click", context.mirror.stopMirror);
context.elements.checkpoint.captureState.addEventListener("click", () => context.connection.send("state.checkpoint"));
context.elements.checkpoint.restoreState.addEventListener("click", context.checkpoint.restoreState);
context.elements.checkpoint.diffState.addEventListener("click", () => context.checkpoint.sendJSON("state.diff", context.elements.checkpoint.stateSnapshot.value));
context.elements.checkpoint.recordInput.addEventListener("click", () => context.connection.send("input.record.start"));
context.elements.checkpoint.stopRecording.addEventListener("click", () => context.connection.send("input.record.stop"));
context.elements.checkpoint.replayInput.addEventListener("click", () => context.checkpoint.sendJSON("input.replay", context.elements.checkpoint.inputRecording.value));
context.elements.logs.logLevel.addEventListener("change", context.logs.renderLog);
context.elements.logs.logSearch.addEventListener("input", context.logs.renderLog);
context.elements.logs.logModule.addEventListener("input", context.logs.renderLog);
context.elements.logs.clearLog.addEventListener("click", context.logs.clear);
context.elements.logs.pauseLog.addEventListener("click", context.logs.pause);
context.elements.logs.exportLog.addEventListener("click", context.logs.exportJSONL);
context.input.installMirrorInput();

// The browser host announces readiness after its Wasm reactor is initialized.
// Waiting for that announcement avoids racing a large debug module download.
if (new URLSearchParams(location.search).get("transport") === "browser") {
  document.body.classList.add("browserHost");
  context.elements.connection.endpoint.value = "browser://guava";
  context.elements.connection.endpoint.readOnly = true;
  window.addEventListener("message", (event) => {
    if (event.origin === location.origin && event.source === window.parent &&
        event.data?.type === "guava.devtools.ready" && !context.session.connection.ws) context.connection.connect();
  });
  window.parent.postMessage({ type: "guava.devtools.probe" }, location.origin);
}

// CLI-managed sessions pass their authenticated endpoint without manual port entry.
const launchEndpoint = new URLSearchParams(window.location.search).get("endpoint");
if (launchEndpoint && /^wss?:\/\//.test(launchEndpoint)) {
  context.elements.connection.endpoint.value = launchEndpoint;
  context.connection.connect();
}

return context;
})();
