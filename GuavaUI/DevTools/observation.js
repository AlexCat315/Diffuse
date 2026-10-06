// Observation is deliberately separate from checkpoint/restore: read-only,
// explicitly registered fields, and values only for the checked watch list.
const observation = { registered: [], values: new Map(), watched: new Set(), events: [], recording: false, pending: false, dropped: 0, watchRequestID: null };
const observationEl = id => document.getElementById(id);
function handleObservationEnvelope(env) {
  if (["state.list.ok", "state.subscribe.ok", "state.observation"].includes(env.type)) {
    if (env.type === "state.subscribe.ok" && env.id !== observation.watchRequestID) return true;
    observation.registered = env.payload?.registered ?? [];
    const live = new Set(observation.registered.map(item => item.id));
    const removed = [...observation.watched].filter(id => !live.has(id));
    for (const id of removed) { observation.watched.delete(id); observation.values.delete(id); }
    if (removed.length) observation.watchRequestID = send("state.subscribe", {ids: [...observation.watched]});
    if (env.type !== "state.list.ok") observation.values = new Map((env.payload?.values ?? []).map(v => [v.id, v]));
    renderStateRegistry(); observationControls(); return true;
  }
  if (env.type === "timeline.subscribe.ok" || env.type === "timeline.events") {
    observation.recording = true; observation.pending = false;
    const known = new Set(observation.events.map(e => e.sequence));
    for (const event of env.payload?.events ?? []) if (!known.has(event.sequence)) observation.events.push(event);
    if (observation.events.length > 2048) observation.events.splice(0, observation.events.length - 2048);
    observation.dropped = env.payload?.dropped ?? observation.dropped;
    queueTimelineRender(); observationControls(); return true;
  }
  if (env.type === "timeline.unsubscribe.ok") {
    observation.recording = false; observation.pending = false; observationControls(); renderTimeline(); return true;
  }
  if (env.type === "timeline.subscribe.err" || env.type === "timeline.unsubscribe.err") {
    observation.pending = false;
    if (env.type === "timeline.subscribe.err") observation.recording = false;
    observationControls();
  }
  return false;
}
function watchState(id, enabled) {
  if (enabled) observation.watched.add(id); else { observation.watched.delete(id); observation.values.delete(id); }
  observation.watchRequestID = send("state.subscribe", { ids: [...observation.watched] }); renderStateRegistry(); observationControls();
}
function renderStateRegistry() {
  const list = observationEl("registeredStates");
  const selected = findNode(state.tree, state.selectedId);
  const scope = selected?.ownerScopeID ?? (selected?.recomposition ? nodeId(selected) : null);
  const onlySelected = observationEl("stateSelectedOnly").checked;
  const signature = JSON.stringify([state.connected, onlySelected ? scope : null, onlySelected,
    observation.registered, [...observation.watched], [...observation.values]]);
  if (signature === observation.registrySignature) return;
  observation.registrySignature = signature;
  list.replaceChildren();
  const entries = observation.registered.filter(item => !onlySelected || (scope && item.scopeID === scope));
  observationEl("stateWatchCount").textContent = `${observation.watched.size} watched · ${observation.registered.length} exposed`;
  for (const item of entries) {
    const row = document.createElement("label"); row.className = "stateWatchRow";
    const checkbox = document.createElement("input"); checkbox.type = "checkbox";
    checkbox.checked = observation.watched.has(item.id);
    checkbox.disabled = !state.connected || (!checkbox.checked && observation.watched.size >= 128);
    checkbox.addEventListener("change", () => watchState(item.id, checkbox.checked));
    const label = document.createElement("span"); label.textContent = `${item.name}${item.scopeID ? ' · scope ' + item.scopeID : ''}`;
    label.title = item.valueType;
    const value = document.createElement("code"), observed = observation.values.get(item.id);
    value.textContent = observed ? observed.summary + (observed.truncated ? "… (truncated)" : "") : checkbox.checked ? "Waiting…" : "Select to observe";
    row.append(checkbox, label, value); list.append(row);
  }
  if (!entries.length) list.textContent = onlySelected ? "No exposed state in this component." : "No exposed state. Register providers or use @State(expose: true).";
}
function observationControls() {
  const active = state.connected && hasCapability("state.observe");
  observationEl("refreshStates").disabled = !active;
  observationEl("stopWatching").disabled = !active || !observation.watched.size;
  observationEl("startTimeline").disabled = !state.connected || !hasCapability("timeline") || observation.recording || observation.pending;
  observationEl("stopTimeline").disabled = !observation.recording || observation.pending || !state.connected;
  observationEl("exportTimeline").disabled = !observation.events.length;
}
function queueTimelineRender() {
  if (observation.timelineRenderFrame != null) return;
  observation.timelineRenderFrame = requestAnimationFrame(() => { observation.timelineRenderFrame = null; renderTimeline(); });
}
function renderTimeline() {
  const list = observationEl("timelineEvents"); list.replaceChildren();
  const filter = observationEl("timelinePhase").value;
  const events = observation.events.filter(e => !filter || e.phase === filter).slice(-120);
  observationEl("timelineStatus").textContent = `${observation.recording ? "Recording" : "Stopped"} · ${observation.events.length} events${observation.dropped ? ' · ' + observation.dropped + ' evicted at host' : ''}`;
  if (!events.length) { list.textContent = "Start recording, then interact with the app."; return; }
  const start = Math.min(...events.map(e => e.startMs));
  const span = Math.max(0.001, ...events.map(e => e.startMs + e.durationMs - start));
  for (const event of events) {
    const row = document.createElement("button"); row.className = "timelineRow";
    row.title = `Start ${event.startMs.toFixed(3)} ms · ${event.name}\n${(event.reasons ?? []).map(r => r.kind + (r.detail ? ': ' + r.detail : '')).join('\n')}`;
    row.disabled = !event.scopeID || !findNode(state.tree, event.scopeID);
    row.onclick = () => { const node = findNode(state.tree, event.scopeID); if (node) selectNode(node); };
    const label = document.createElement("span"); label.textContent = `${event.phase} · ${compactTag(event.name)} · ${event.durationMs.toFixed(3)} ms`;
    const track = document.createElement("span"); track.className = "timelineTrack";
    const bar = document.createElement("span"); bar.className = "timelineBar " + escapeClass(event.phase);
    bar.style.marginLeft = `${(event.startMs - start) / span * 100}%`;
    bar.style.width = `${Math.max(0.3, event.durationMs / span * 100)}%`; track.append(bar);
    row.append(label, track); list.append(row);
  }
}
function resetObservations() {
  if (observation.timelineRenderFrame != null) cancelAnimationFrame(observation.timelineRenderFrame);
  observation.timelineRenderFrame = null;
  observation.registered = []; observation.values.clear(); observation.watched.clear(); observation.events = [];
  observation.recording = false; observation.pending = false; observation.dropped = 0; observation.watchRequestID = null;
  observationEl("stateSelectedOnly").checked = false; observationEl("timelinePhase").value = "";
  renderStateRegistry(); renderTimeline(); observationControls();
}
function timelineTrace() {
  return { displayTimeUnit: "ms", traceEvents: observation.events.map(e => ({ name: e.name, cat: e.phase, ph: "X", pid: 1,
    tid: ({component: 1, recomposition: 1, layout: 2, draw: 3})[e.phase] ?? 4, ts: e.startMs * 1000, dur: e.durationMs * 1000,
    args: { scopeID: e.scopeID, reasons: e.reasons ?? [] } })) };
}
document.addEventListener("DOMContentLoaded", () => {
  observationEl("refreshStates").onclick = () => send("state.list");
  observationEl("stateSelectedOnly").onchange = renderStateRegistry;
  observationEl("stopWatching").onclick = () => {
    send("state.unsubscribe"); observation.watchRequestID = null; observation.watched.clear(); observation.values.clear(); renderStateRegistry(); observationControls();
  };
  observationEl("startTimeline").onclick = () => {
    observation.events = []; observation.dropped = 0; observation.pending = true;
    send("timeline.subscribe"); observationControls(); renderTimeline();
  };
  observationEl("stopTimeline").onclick = () => { observation.pending = true; send("timeline.unsubscribe"); observationControls(); };
  observationEl("timelinePhase").onchange = renderTimeline;
  observationEl("exportTimeline").onclick = () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(timelineTrace())], {type: "application/json"}));
    const link = document.createElement("a"); link.href = url; link.download = "guava-timeline.json"; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  resetObservations();
});
