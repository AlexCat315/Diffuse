InspectorModules.logs = function(context) {
const state = context.session.logs;
const elements = context.elements.logs;
const key = entry => entry.sequence == null ? null : `${entry.process?.runID}:${entry.process?.pid}:${entry.sequence}`;

function appendLog(entry) {
  if (!entry) return;
  const identity = key(entry);
  if (identity && state.seen.has(identity)) return;
  if (identity) state.seen.add(identity);
  if (entry.label === "com.guava.logging" && entry.metadata?.total_dropped != null) {
    state.coreDropped = Math.max(state.coreDropped, Number(entry.metadata.total_dropped) || 0);
  }
  state.logEntries.push(entry);
  while (state.logEntries.length > 1000) {
    const old = state.logEntries.shift(); state.seen.delete(key(old)); state.localDropped++;
  }
  queueRender();
}
function acceptSnapshot(snapshot) {
  state.coreDropped = Math.max(state.coreDropped, snapshot?.dropped ?? 0);
  for (const entry of snapshot?.records ?? []) appendLog(entry);
  queueRender();
}
function deliveryGap(payload) { state.transportDropped += payload?.dropped ?? 0; queueRender(); }
function queueRender() {
  if (state.paused || state.renderFrame != null) return;
  state.renderFrame = requestAnimationFrame(() => { state.renderFrame = null; renderLog(); });
}
function filteredEntries() {
  const minimum = context.format.logLevelRank(elements.logLevel.value);
  const query = elements.logSearch.value.trim().toLocaleLowerCase();
  const module = elements.logModule.value.trim();
  return state.logEntries.filter(entry => {
    if (context.format.logLevelRank(entry.level) < minimum) return false;
    if (module && entry.label !== module && !entry.label?.startsWith(module + ".")) return false;
    return !query || `${entry.label ?? ""} ${entry.message ?? ""} ${JSON.stringify(entry.metadata ?? {})} ${entry.location?.file ?? ""} ${entry.process?.runID ?? ""}`.toLocaleLowerCase().includes(query);
  });
}
function renderLog() {
  if (state.paused) return;
  const entries = filteredEntries();
  elements.logCount.textContent = `${entries.length}/${state.logEntries.length}`;
  elements.logStatus.textContent = `Queue dropped ${state.coreDropped} · transport dropped ${state.transportDropped} · locally overwritten ${state.localDropped} · showing latest 250`;
  elements.log.replaceChildren();
  if (!entries.length) {
    elements.log.className = "log empty";
    elements.log.textContent = state.logEntries.length ? "No log entries match the filters." : "No log entries.";
    return;
  }
  elements.log.className = "log";
  const fragment = document.createDocumentFragment();
  for (const entry of entries.slice(-250)) {
    const row = document.createElement("details"); row.className = `logRecord ${context.format.escapeClass(entry.level ?? "info")}`;
    const summary = document.createElement("summary");
    const stamp = Number.isFinite(entry.timestamp) ? new Date(entry.timestamp * 1000).toLocaleTimeString() : "";
    summary.textContent = `${stamp} ${(entry.level ?? "info").toUpperCase()} [${entry.label ?? "client"}] ${entry.message ?? ""}`;
    const detail = document.createElement("pre");
    detail.textContent = JSON.stringify({sequence: entry.sequence, process: entry.process, location: entry.location, metadata: entry.metadata}, null, 2);
    row.append(summary, detail); fragment.appendChild(row);
  }
  elements.log.appendChild(fragment); elements.log.scrollTop = elements.log.scrollHeight;
}
function clear() {
  state.logEntries = []; state.seen.clear(); state.localDropped = state.coreDropped = state.transportDropped = 0;
  queueRender();
}
function pause() {
  state.paused = !state.paused;
  elements.pauseLog.textContent = state.paused ? "Resume" : "Pause display";
  if (!state.paused) queueRender();
}
function exportJSONL() {
  const blob = new Blob([filteredEntries().map(entry => JSON.stringify(entry)).join("\n") + "\n"], {type: "application/x-ndjson"});
  const url = URL.createObjectURL(blob), link = document.createElement("a");
  link.href = url; link.download = "guava-logs.jsonl"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
return { appendLog, acceptSnapshot, deliveryGap, renderLog, clear, pause, exportJSONL };
};
