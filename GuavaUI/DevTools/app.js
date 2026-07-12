const state = {
  ws: null,
  requestId: 1,
  connected: false,
  capabilities: new Set(),
  tree: null,
  snapshot: null,
  selectedId: null,
  treeQuery: "",
  mirrorActive: false,
  mirrorFrame: null,
  mirrorImageLoading: false,
  pendingMirrorFrame: null,
  mirrorDecodeGeneration: 0,
  pointerDown: false,
  pointerButton: 0,
  lastPointer: null,
  pressedKeys: new Map(),
  logEntries: [],
  timingFrames: [],
};

const el = {
  endpoint: document.getElementById("endpoint"),
  status: document.getElementById("status"),
  connect: document.getElementById("connect"),
  disconnect: document.getElementById("disconnect"),
  refreshTree: document.getElementById("refreshTree"),
  treeSearch: document.getElementById("treeSearch"),
  treeCount: document.getElementById("treeCount"),
  startMirror: document.getElementById("startMirror"),
  stopMirror: document.getElementById("stopMirror"),
  mirrorFPS: document.getElementById("mirrorFPS"),
  mirrorQuality: document.getElementById("mirrorQuality"),
  mirror: document.getElementById("mirror"),
  mirrorStatus: document.getElementById("mirrorStatus"),
  mirrorState: document.getElementById("mirrorState"),
  mirrorImage: document.getElementById("mirrorImage"),
  tree: document.getElementById("tree"),
  details: document.getElementById("details"),
  runtime: document.getElementById("runtime"),
  timing: document.getElementById("timing"),
  log: document.getElementById("log"),
  clearLog: document.getElementById("clearLog"),
  logCount: document.getElementById("logCount"),
  logLevel: document.getElementById("logLevel"),
  logSearch: document.getElementById("logSearch"),
  captureState: document.getElementById("captureState"),
  restoreState: document.getElementById("restoreState"),
  stateSnapshot: document.getElementById("stateSnapshot"),
};

el.connect.addEventListener("click", connect);
el.disconnect.addEventListener("click", disconnect);
el.refreshTree.addEventListener("click", () => send("tree.subscribe"));
el.treeSearch.addEventListener("input", () => {
  state.treeQuery = el.treeSearch.value.trim().toLocaleLowerCase();
  renderTree();
});
el.startMirror.addEventListener("click", startMirror);
el.stopMirror.addEventListener("click", stopMirror);
el.captureState.addEventListener("click", () => send("state.checkpoint"));
el.restoreState.addEventListener("click", restoreState);
el.logLevel.addEventListener("change", renderLog);
el.logSearch.addEventListener("input", renderLog);
el.clearLog.addEventListener("click", () => {
  state.logEntries = [];
  renderLog();
});
installMirrorInput();

function connect() {
  disconnect();
  const url = el.endpoint.value.trim();
  if (!url) return;

  let ws;
  try {
    ws = new WebSocket(url);
  } catch (error) {
    setStatus("Invalid Endpoint", false);
    appendLog({ level: "error", label: "client", message: String(error) });
    return;
  }
  state.ws = ws;
  state.capabilities.clear();
  setStatus("Connecting", false);

  ws.addEventListener("open", () => {
    state.connected = true;
    setStatus("Connected", true);
    setControls(true);
    setMirrorInactive("No mirror frame. Click Start after connecting.");
  });

  ws.addEventListener("message", (event) => {
    try {
      handleEnvelope(JSON.parse(event.data));
    } catch (error) {
      appendLog({ level: "error", label: "client", message: `Failed to parse message: ${error}` });
    }
  });

  ws.addEventListener("close", () => {
    if (state.ws === ws) {
      state.ws = null;
      state.connected = false;
      state.capabilities.clear();
      setControls(false);
      setStatus("Disconnected", false);
      setMirrorInactive("Disconnected.");
      clearSessionViews();
    }
  });

  ws.addEventListener("error", () => {
    if (state.ws === ws) setStatus("Connection Error", false);
  });
}

function disconnect() {
  releaseRemoteInput();
  if (state.selectedId) send("select.clear");
  if (state.ws) {
    state.ws.close();
  }
  state.ws = null;
  state.connected = false;
  state.capabilities.clear();
  setControls(false);
  setMirrorInactive("Disconnected.");
  clearSessionViews();
}

function send(type, payload = undefined, expectsResponse = true) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return;
  const envelope = { type, payload };
  if (expectsResponse) envelope.id = state.requestId++;
  state.ws.send(JSON.stringify(envelope));
}

function sendInput(payload) {
  // Input is a high-frequency notification stream; request IDs would make
  // the server emit an unnecessary acknowledgement for every pointer move.
  send("mirror.input", payload, false);
}

function handleEnvelope(env) {
  switch (env.type) {
    case "hello":
      state.capabilities = new Set(env.payload?.capabilities ?? []);
      send("hello.ack");
      if (hasCapability("tree")) send("tree.subscribe");
      if (hasCapability("log")) send("log.subscribe");
      if (hasCapability("timing")) send("timing.subscribe");
      setControls(true);
      appendLog({
        level: "info",
        label: "host",
        message: `Connected to ${env.payload?.host?.appTitle ?? "GuavaUI"} (${env.payload?.protocol ?? "unknown protocol"})`,
      });
      break;
    case "tree.snapshot":
    case "tree.delta":
      state.snapshot = env.payload ?? null;
      state.tree = env.payload?.root ?? null;
      syncSelection();
      renderTree();
      renderRuntime(env.payload);
      break;
    case "log.entry":
      appendLog(env.payload);
      break;
    case "timing.frame":
      renderTiming(env.payload);
      break;
    case "state.checkpoint.ok":
      el.stateSnapshot.value = JSON.stringify(env.payload ?? {}, null, 2);
      appendLog({ level: "info", label: "state", message: "Checkpoint captured." });
      break;
    case "state.restore.ok":
      appendLog({ level: "info", label: "state", message: "Checkpoint restore requested." });
      break;
    case "mirror.frame":
      renderMirror(env.payload);
      break;
    case "mirror.stopped":
      setMirrorInactive(`Stopped: ${env.payload?.reason ?? "unknown"}`);
      appendLog({ level: "info", label: "mirror", message: `Stopped: ${env.payload?.reason ?? "unknown"}` });
      break;
    case "mirror.start.ok":
      setMirrorWaiting();
      break;
    case "mirror.stop.ok":
      setMirrorInactive("Stopped.");
      break;
    default:
      if (env.type?.endsWith(".err")) {
        if (env.type.startsWith("mirror.")) {
          setMirrorInactive(env.payload?.message ?? "Mirror request failed.");
        }
        appendLog({ level: "error", label: env.type, message: env.payload?.message ?? "Request failed" });
      }
      break;
  }
}

function renderTree() {
  el.tree.innerHTML = "";
  if (!state.tree) {
    el.tree.className = "tree empty";
    el.tree.textContent = "No root node.";
    el.treeCount.textContent = "";
    renderDetails(null);
    return;
  }
  el.tree.className = "tree";
  const total = countTreeNodes(state.tree);
  const shown = renderNode(el.tree, state.tree, 0);
  el.treeCount.textContent = state.treeQuery ? `${shown}/${total}` : String(total);
  if (shown === 0) {
    el.tree.className = "tree empty";
    el.tree.textContent = "No nodes match the current filter.";
  }
}

function renderNode(parent, node, depth) {
  if (state.treeQuery && !treeContainsQuery(node, state.treeQuery)) return 0;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "treeNode" + (nodeId(node) === state.selectedId ? " selected" : "");
  button.style.paddingLeft = `${6 + depth * 14}px`;
  button.innerHTML = `<span class="nodeLabel">${escapeHtml(nodeLabel(node))}</span>` +
    `<span class="nodeMuted">${escapeHtml(nodeBadge(node))}</span>`;
  button.addEventListener("click", () => selectNode(node));
  parent.appendChild(button);

  let count = 1;
  for (const child of node.children ?? []) {
    count += renderNode(parent, child, depth + 1);
  }
  return count;
}

function selectNode(node) {
  state.selectedId = nodeId(node);
  send("select.node", { id: state.selectedId });
  renderTree();
  renderDetails(node);
}

function renderDetails(node) {
  if (!node) {
    el.details.className = "details empty";
    el.details.textContent = "Select a node in the tree.";
    return;
  }
  el.details.className = "details";
  el.details.textContent = JSON.stringify({
    id: node.id,
    elementID: node.elementID,
    viewTag: node.viewTag,
    debugName: node.debugName,
    frame: node.frame,
    absoluteFrame: node.absoluteFrame,
    contentOffset: node.contentOffset,
    zIndex: node.zIndex,
    opacity: node.opacity,
    layoutRole: node.layoutRole,
    semanticRole: node.semanticRole,
    flags: node.flags,
  }, null, 2);
}

function renderTiming(payload) {
  if (!payload) return;
  state.timingFrames.push(payload);
  if (state.timingFrames.length > 120) state.timingFrames.shift();
  const recent = state.timingFrames.slice(-60);
  const average = (key) => recent.reduce((sum, frame) => sum + finiteNumber(frame[key]), 0) / recent.length;
  const totalMs = finiteNumber(payload.totalMs);
  el.timing.className = "details";
  el.timing.textContent = JSON.stringify({
    frame: payload.frame,
    fps: totalMs > 0 ? round(1000 / totalMs, 1) : null,
    currentMs: {
      layout: round(payload.layoutMs),
      draw: round(payload.drawMs),
      present: round(payload.presentMs),
      total: round(payload.totalMs),
    },
    average60Ms: {
      layout: round(average("layoutMs")),
      draw: round(average("drawMs")),
      present: round(average("presentMs")),
      total: round(average("totalMs")),
    },
    nodes: payload.nodeCount,
    batches: payload.batchCount,
  }, null, 2);
}

function renderMirror(payload) {
  if (!payload?.jpegBase64) return;
  state.mirrorActive = true;
  if (state.mirrorImageLoading) {
    // Keep only the newest frame while the browser decodes the current one.
    // Replacing <img>.src faster than decode can complete leaves the mirror
    // permanently black on high-DPI windows.
    state.pendingMirrorFrame = payload;
    return;
  }
  decodeMirrorFrame(payload, state.mirrorDecodeGeneration);
}

function decodeMirrorFrame(payload, generation) {
  state.mirrorImageLoading = true;
  const candidate = new Image();
  candidate.src = `data:image/jpeg;base64,${payload.jpegBase64}`;
  const decoded = typeof candidate.decode === "function"
    ? candidate.decode()
    : new Promise((resolve, reject) => {
        candidate.onload = resolve;
        candidate.onerror = reject;
      });
  decoded.then(() => {
    if (generation !== state.mirrorDecodeGeneration || !state.mirrorActive) return;
    state.mirrorFrame = payload;
    el.mirrorImage.src = candidate.src;
    el.mirror.classList.add("hasFrame");
    el.mirrorStatus.textContent = `Frame ${payload.seq ?? ""}`.trim();
    el.mirrorState.textContent = "";
  }).catch((error) => {
    appendLog({ level: "error", label: "mirror", message: `Frame decode failed: ${error}` });
  }).finally(() => {
    if (generation !== state.mirrorDecodeGeneration) return;
    state.mirrorImageLoading = false;
    const pending = state.pendingMirrorFrame;
    state.pendingMirrorFrame = null;
    if (pending && state.mirrorActive) decodeMirrorFrame(pending, generation);
  });
  setControls(state.connected);
}

function startMirror() {
  state.mirrorActive = true;
  state.mirrorFrame = null;
  el.mirrorImage.removeAttribute("src");
  el.mirror.classList.remove("hasFrame");
  setMirrorWaiting();
  send("mirror.start", {
    fps: clamp(Number(el.mirrorFPS.value), 1, 60, 15),
    quality: clamp(Number(el.mirrorQuality.value), 0.1, 1, 0.75),
  });
}

function stopMirror() {
  releaseRemoteInput();
  send("mirror.stop");
  setMirrorInactive("Stopping...");
}

function setMirrorWaiting() {
  state.mirrorActive = true;
  el.mirror.classList.remove("hasFrame");
  el.mirrorStatus.textContent = "Waiting";
  el.mirrorState.textContent = "Mirror requested. Waiting for the first frame...";
  setControls(state.connected);
}

function setMirrorInactive(message) {
  releaseRemoteInput();
  state.mirrorDecodeGeneration += 1;
  state.mirrorActive = false;
  state.mirrorFrame = null;
  state.mirrorImageLoading = false;
  state.pendingMirrorFrame = null;
  state.pointerDown = false;
  el.mirror.classList.remove("hasFrame");
  el.mirrorImage.removeAttribute("src");
  el.mirrorStatus.textContent = state.connected ? "Idle" : "Off";
  el.mirrorState.textContent = message || "No mirror frame. Click Start after connecting.";
  setControls(state.connected);
}

function restoreState() {
  let snapshot;
  try {
    snapshot = JSON.parse(el.stateSnapshot.value || "{}");
  } catch (error) {
    appendLog({ level: "error", label: "state", message: `Invalid JSON: ${error.message}` });
    return;
  }
  const valid = snapshot && !Array.isArray(snapshot) && typeof snapshot === "object" &&
    Object.values(snapshot).every((value) => typeof value === "string");
  if (!valid) {
    appendLog({ level: "error", label: "state", message: "Checkpoint must be an object with string values." });
    return;
  }
  send("state.restore", snapshot);
}

function renderRuntime(snapshot) {
  if (!snapshot) {
    el.runtime.className = "details empty";
    el.runtime.textContent = "No tree snapshot.";
    return;
  }
  const invalidations = snapshot.invalidations ?? [];
  const tail = invalidations.slice(-8).map((entry) => ({
    target: entry.target,
    phase: entry.phase,
    source: entry.source,
  }));
  el.runtime.className = "details";
  el.runtime.textContent = JSON.stringify({
    renderInventory: snapshot.renderInventory ?? null,
    inputInventory: summarizeInputInventory(snapshot.inputInventory),
    invalidations: tail,
  }, null, 2);
}

function summarizeInputInventory(inputInventory) {
  if (!inputInventory) return null;
  return {
    nodeCount: inputInventory.nodeCount,
    focusableCount: inputInventory.focusables?.length ?? 0,
    hitTestableCount: inputInventory.hitTestables?.length ?? 0,
  };
}

function installMirrorInput() {
  el.mirror.addEventListener("pointermove", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    state.lastPointer = point;
    const scale = mirrorScale();
    sendInput({
      kind: "pointerMove",
      x: point.x,
      y: point.y,
      deltaX: (event.movementX || 0) * scale.x,
      deltaY: (event.movementY || 0) * scale.y,
      modifiers: modifiers(event),
    });
  });

  el.mirror.addEventListener("pointerdown", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    state.pointerDown = true;
    state.pointerButton = event.button;
    state.lastPointer = point;
    el.mirror.setPointerCapture?.(event.pointerId);
    el.mirror.focus?.();
    sendInput({
      kind: "pointerDown",
      x: point.x,
      y: point.y,
      button: event.button,
      clickCount: event.detail || 1,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  });

  el.mirror.addEventListener("pointerup", (event) => {
    const point = mirrorPoint(event);
    if (!point && !state.lastPointer) return;
    state.pointerDown = false;
    sendInput({
      kind: "pointerUp",
      x: (point ?? state.lastPointer).x,
      y: (point ?? state.lastPointer).y,
      button: event.button,
      clickCount: event.detail || 1,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  });

  el.mirror.addEventListener("pointercancel", releasePointer);

  el.mirror.addEventListener("wheel", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    const scale = mirrorScale();
    sendInput({
      kind: "wheel",
      x: point.x,
      y: point.y,
      deltaX: event.deltaX * scale.x,
      deltaY: event.deltaY * scale.y,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  }, { passive: false });

  el.mirror.addEventListener("keydown", (event) => {
    if (!state.connected) return;
    if (event.code) state.pressedKeys.set(event.code, keyCode(event));
    sendInput({
      kind: "keyDown",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    if (isTextKey(event)) {
      sendInput({
        kind: "text",
        text: event.key,
      });
    }
    event.preventDefault();
  });

  el.mirror.addEventListener("keyup", (event) => {
    if (!state.connected) return;
    sendInput({
      kind: "keyUp",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    state.pressedKeys.delete(event.code);
    event.preventDefault();
  });

  el.mirror.addEventListener("blur", releaseRemoteInput);
}

function mirrorPoint(event) {
  if (!state.connected || !state.mirrorFrame) return null;
  const rect = el.mirrorImage.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return null;
  const localX = event.clientX - rect.left;
  const localY = event.clientY - rect.top;
  if (localX < 0 || localY < 0 || localX > rect.width || localY > rect.height) {
    return null;
  }
  return {
    x: (localX / rect.width) * state.mirrorFrame.logicalWidth,
    y: (localY / rect.height) * state.mirrorFrame.logicalHeight,
  };
}

function mirrorScale() {
  const rect = el.mirrorImage.getBoundingClientRect();
  if (!state.mirrorFrame || rect.width <= 0 || rect.height <= 0) return { x: 1, y: 1 };
  return {
    x: state.mirrorFrame.logicalWidth / rect.width,
    y: state.mirrorFrame.logicalHeight / rect.height,
  };
}

function releasePointer(event) {
  if (!state.pointerDown) return;
  const point = (event && mirrorPoint(event)) || state.lastPointer || { x: 0, y: 0 };
  sendInput({
    kind: "pointerUp",
    x: point.x,
    y: point.y,
    button: state.pointerButton,
    clickCount: 1,
    modifiers: event ? modifiers(event) : 0,
  });
  state.pointerDown = false;
}

function releaseRemoteInput() {
  releasePointer();
  for (const [code, codePoint] of state.pressedKeys) {
    sendInput({
      kind: "keyUp",
      key: code,
      keyCode: codePoint,
      modifiers: 0,
      isRepeat: false,
    });
  }
  state.pressedKeys.clear();
}

function modifiers(event) {
  return (event.shiftKey ? 1 : 0) |
    (event.ctrlKey ? 2 : 0) |
    (event.altKey ? 4 : 0) |
    (event.metaKey ? 8 : 0);
}

function keyCode(event) {
  if (Number.isFinite(event.keyCode) && event.keyCode > 0) return event.keyCode;
  return event.key?.length === 1 ? event.key.codePointAt(0) : 0;
}

function isTextKey(event) {
  return event.key?.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey;
}

function appendLog(entry) {
  if (!entry) return;
  state.logEntries.push(entry);
  if (state.logEntries.length > 250) {
    state.logEntries.splice(0, state.logEntries.length - 250);
  }
  renderLog();
}

function renderLog() {
  el.log.innerHTML = "";
  const minimum = logLevelRank(el.logLevel.value);
  const query = el.logSearch.value.trim().toLocaleLowerCase();
  const entries = state.logEntries.filter((entry) => {
    if (logLevelRank(entry.level) < minimum) return false;
    if (!query) return true;
    return `${entry.label ?? ""} ${entry.message ?? ""} ${entry.source ?? ""}`
      .toLocaleLowerCase().includes(query);
  });
  el.logCount.textContent = `${entries.length}/${state.logEntries.length}`;
  if (entries.length === 0) {
    el.log.className = "log empty";
    el.log.textContent = state.logEntries.length === 0 ? "No log entries." : "No log entries match the filters.";
    return;
  }
  el.log.className = "log";
  for (const entry of entries.slice(-250)) {
    const row = document.createElement("div");
    row.className = `logEntry ${escapeClass(entry.level ?? "info")}`;
    row.innerHTML = `<span class="level">${escapeHtml(entry.level ?? "info")}</span>` +
      `<span>${escapeHtml(entry.label ?? "log")}: ${escapeHtml(entry.message ?? "")}</span>`;
    el.log.appendChild(row);
  }
  el.log.scrollTop = el.log.scrollHeight;
}

function nodeId(node) {
  return node.elementID ?? node.id;
}

function syncSelection() {
  if (!state.selectedId) return;
  const selected = findNode(state.tree, state.selectedId);
  if (selected) {
    renderDetails(selected);
  } else {
    state.selectedId = null;
    renderDetails(null);
  }
}

function findNode(node, id) {
  if (!node) return null;
  if (nodeId(node) === id || node.id === id || node.elementID === id) return node;
  for (const child of node.children ?? []) {
    const result = findNode(child, id);
    if (result) return result;
  }
  return null;
}

function countTreeNodes(node) {
  if (!node) return 0;
  return 1 + (node.children ?? []).reduce((sum, child) => sum + countTreeNodes(child), 0);
}

function treeContainsQuery(node, query) {
  const searchable = [nodeLabel(node), node.viewTag, node.debugName, node.elementID, node.id]
    .filter(Boolean).join(" ").toLocaleLowerCase();
  if (searchable.includes(query)) return true;
  return (node.children ?? []).some((child) => treeContainsQuery(child, query));
}

function nodeLabel(node) {
  return node.debugName || compactTag(node.viewTag) || node.elementID || node.id || "Node";
}

function nodeBadge(node) {
  const frame = node.absoluteFrame ?? node.frame;
  const size = frame ? `${Math.round(frame.w)}x${Math.round(frame.h)}` : "";
  const flags = [];
  if (node.flags?.focusable) flags.push("focus");
  if (node.flags?.hitTestable === false) flags.push("no-hit");
  if (node.flags?.clipsToBounds) flags.push("clip");
  return [size, ...flags].filter(Boolean).join(" ");
}

function compactTag(tag) {
  if (!tag) return "";
  const parts = String(tag).split(".");
  return parts[parts.length - 1];
}

function setControls(enabled) {
  el.connect.disabled = enabled;
  el.disconnect.disabled = !enabled;
  el.refreshTree.disabled = !enabled || !hasCapability("tree");
  el.startMirror.disabled = !enabled || !hasCapability("mirror") || state.mirrorActive;
  el.stopMirror.disabled = !enabled || !hasCapability("mirror") || !state.mirrorActive;
  el.captureState.disabled = !enabled || !hasCapability("state");
  el.restoreState.disabled = !enabled || !hasCapability("state");
}

function setStatus(text, connected) {
  el.status.textContent = text;
  el.status.className = `status ${connected ? "connected" : "disconnected"}`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function hasCapability(name) {
  return state.capabilities.has(name);
}

function clearSessionViews() {
  state.tree = null;
  state.snapshot = null;
  state.selectedId = null;
  state.timingFrames = [];
  el.treeCount.textContent = "";
  el.tree.className = "tree empty";
  el.tree.textContent = "Connect to a GuavaUI app to inspect the live node tree.";
  renderDetails(null);
  renderRuntime(null);
  el.timing.className = "details empty";
  el.timing.textContent = "No timing sample.";
}

function logLevelRank(level) {
  return ({ trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 })[level] ?? 2;
}

function escapeClass(value) {
  return String(value).replace(/[^a-z0-9_-]/gi, "");
}

function finiteNumber(value) {
  return Number.isFinite(Number(value)) ? Number(value) : 0;
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(finiteNumber(value) * factor) / factor;
}

function clamp(value, minimum, maximum, fallback) {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(minimum, value));
}
