const state = {
  ws: null,
  requestId: 1,
  connected: false,
  tree: null,
  selectedId: null,
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
  mirrorImage: document.getElementById("mirrorImage"),
  tree: document.getElementById("tree"),
  details: document.getElementById("details"),
  timing: document.getElementById("timing"),
  log: document.getElementById("log"),
  clearLog: document.getElementById("clearLog"),
};

el.connect.addEventListener("click", connect);
el.disconnect.addEventListener("click", disconnect);
el.refreshTree.addEventListener("click", () => send("tree.subscribe"));
el.startMirror.addEventListener("click", () => send("mirror.start", { fps: 15, quality: 0.75 }));
el.stopMirror.addEventListener("click", () => send("mirror.stop"));
el.clearLog.addEventListener("click", () => {
  state.logEntries = [];
  renderLog();
});

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
      state.tree = env.payload?.root ?? null;
      renderTree();
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
      appendLog({ level: "info", label: "mirror", message: `Stopped: ${env.payload?.reason ?? "unknown"}` });
      break;
    default:
      if (env.type?.endsWith(".err")) {
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
  button.innerHTML = `${escapeHtml(nodeLabel(node))} <span class="nodeMuted">${escapeHtml(nodeBadge(node))}</span>`;
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
  el.mirrorImage.src = `data:image/jpeg;base64,${payload.jpegBase64}`;
  el.mirror.classList.add("hasFrame");
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
  el.startMirror.disabled = !enabled;
  el.stopMirror.disabled = !enabled;
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
