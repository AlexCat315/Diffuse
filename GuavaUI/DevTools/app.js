const state = {
  ws: null,
  requestId: 1,
  connected: false,
  tree: null,
  snapshot: null,
  selectedId: null,
  mirrorActive: false,
  mirrorFrame: null,
  pointerDown: false,
  logEntries: [],
};

const el = {
  endpoint: document.getElementById("endpoint"),
  status: document.getElementById("status"),
  connect: document.getElementById("connect"),
  disconnect: document.getElementById("disconnect"),
  refreshTree: document.getElementById("refreshTree"),
  startMirror: document.getElementById("startMirror"),
  stopMirror: document.getElementById("stopMirror"),
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
};

el.connect.addEventListener("click", connect);
el.disconnect.addEventListener("click", disconnect);
el.refreshTree.addEventListener("click", () => send("tree.subscribe"));
el.startMirror.addEventListener("click", startMirror);
el.stopMirror.addEventListener("click", stopMirror);
el.clearLog.addEventListener("click", () => {
  state.logEntries = [];
  renderLog();
});
installMirrorInput();

function connect() {
  disconnect();
  const url = el.endpoint.value.trim();
  if (!url) return;

  const ws = new WebSocket(url);
  state.ws = ws;
  setStatus("Connecting", false);

  ws.addEventListener("open", () => {
    state.connected = true;
    setStatus("Connected", true);
    setControls(true);
    setMirrorInactive("No mirror frame. Click Start after connecting.");
    send("hello.ack");
    send("tree.subscribe");
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
      setControls(false);
      setStatus("Disconnected", false);
      setMirrorInactive("Disconnected.");
    }
  });

  ws.addEventListener("error", () => {
    setStatus("Connection Error", false);
  });
}

function disconnect() {
  if (state.ws) {
    state.ws.close();
  }
  state.ws = null;
  state.connected = false;
  setControls(false);
  setMirrorInactive("Disconnected.");
}

function send(type, payload = undefined) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return;
  state.ws.send(JSON.stringify({
    type,
    id: state.requestId++,
    payload,
  }));
}

function handleEnvelope(env) {
  switch (env.type) {
    case "hello":
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
      renderTree();
      renderRuntime(env.payload);
      break;
    case "log.entry":
      appendLog(env.payload);
      break;
    case "timing.frame":
      renderTiming(env.payload);
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
    renderDetails(null);
    return;
  }
  el.tree.className = "tree";
  renderNode(el.tree, state.tree, 0);
}

function renderNode(parent, node, depth) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "treeNode" + (nodeId(node) === state.selectedId ? " selected" : "");
  button.style.paddingLeft = `${6 + depth * 14}px`;
  button.innerHTML = `<span class="nodeLabel">${escapeHtml(nodeLabel(node))}</span>` +
    `<span class="nodeMuted">${escapeHtml(nodeBadge(node))}</span>`;
  button.addEventListener("click", () => selectNode(node));
  parent.appendChild(button);

  for (const child of node.children ?? []) {
    renderNode(parent, child, depth + 1);
  }
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
  el.timing.className = "details";
  el.timing.textContent = JSON.stringify(payload, null, 2);
}

function renderMirror(payload) {
  if (!payload?.jpegBase64) return;
  state.mirrorActive = true;
  state.mirrorFrame = payload;
  el.mirrorImage.src = `data:image/jpeg;base64,${payload.jpegBase64}`;
  el.mirror.classList.add("hasFrame");
  el.mirrorStatus.textContent = `Frame ${payload.seq ?? ""}`.trim();
  el.mirrorState.textContent = "";
  setControls(state.connected);
}

function startMirror() {
  state.mirrorActive = true;
  state.mirrorFrame = null;
  el.mirrorImage.removeAttribute("src");
  el.mirror.classList.remove("hasFrame");
  setMirrorWaiting();
  send("mirror.start", { fps: 15, quality: 0.75 });
}

function stopMirror() {
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
  state.mirrorActive = false;
  state.mirrorFrame = null;
  state.pointerDown = false;
  el.mirror.classList.remove("hasFrame");
  el.mirrorImage.removeAttribute("src");
  el.mirrorStatus.textContent = state.connected ? "Idle" : "Off";
  el.mirrorState.textContent = message || "No mirror frame. Click Start after connecting.";
  setControls(state.connected);
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
    send("mirror.input", {
      kind: "pointerMove",
      x: point.x,
      y: point.y,
      deltaX: event.movementX || 0,
      deltaY: event.movementY || 0,
      modifiers: modifiers(event),
    });
  });

  el.mirror.addEventListener("pointerdown", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    state.pointerDown = true;
    el.mirror.setPointerCapture?.(event.pointerId);
    el.mirror.focus?.();
    send("mirror.input", {
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
    if (!point) return;
    state.pointerDown = false;
    send("mirror.input", {
      kind: "pointerUp",
      x: point.x,
      y: point.y,
      button: event.button,
      clickCount: event.detail || 1,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  });

  el.mirror.addEventListener("wheel", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    send("mirror.input", {
      kind: "wheel",
      x: point.x,
      y: point.y,
      deltaX: event.deltaX,
      deltaY: event.deltaY,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  }, { passive: false });

  el.mirror.addEventListener("keydown", (event) => {
    if (!state.connected) return;
    send("mirror.input", {
      kind: "keyDown",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    if (isTextKey(event)) {
      send("mirror.input", {
        kind: "text",
        text: event.key,
      });
    }
    event.preventDefault();
  });

  el.mirror.addEventListener("keyup", (event) => {
    if (!state.connected) return;
    send("mirror.input", {
      kind: "keyUp",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    event.preventDefault();
  });
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
  if (state.logEntries.length === 0) {
    el.log.className = "log empty";
    el.log.textContent = "No log entries.";
    return;
  }
  el.log.className = "log";
  for (const entry of state.logEntries.slice(-250)) {
    const row = document.createElement("div");
    row.className = "logEntry";
    row.innerHTML = `<span class="level">${escapeHtml(entry.level ?? "info")}</span>` +
      `<span>${escapeHtml(entry.label ?? "log")}: ${escapeHtml(entry.message ?? "")}</span>`;
    el.log.appendChild(row);
  }
  el.log.scrollTop = el.log.scrollHeight;
}

function nodeId(node) {
  return node.elementID ?? node.id;
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
  el.refreshTree.disabled = !enabled;
  el.startMirror.disabled = !enabled || state.mirrorActive;
  el.stopMirror.disabled = !enabled || !state.mirrorActive;
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
