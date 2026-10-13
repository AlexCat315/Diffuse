InspectorModules.connection = function(context) {
function connect() {
  disconnect();
  const url = context.elements.connection.endpoint.value.trim();
  if (!url) return;

  let ws;
  try {
    ws = url === "browser://guava" ? new window.GuavaBrowserConnection() : new WebSocket(url);
  } catch (error) {
    context.controls.setStatus("Invalid Endpoint", false);
    context.logs.appendLog({ level: "error", label: "client", message: String(error) });
    return;
  }
  context.session.connection.ws = ws;
  context.session.connection.capabilities.clear();
  context.controls.setStatus("Connecting", false);

  ws.addEventListener("open", () => {
    if (context.session.connection.ws !== ws) return;
    context.session.connection.connected = true;
    context.controls.setStatus("Connected", true);
    context.controls.setControls(true);
    context.mirror.setMirrorInactive("No mirror frame. Click Start after connecting.");
  });

  ws.addEventListener("message", (event) => {
    if (context.session.connection.ws !== ws) return;
    try {
      context.messages.handleEnvelope(JSON.parse(event.data));
    } catch (error) {
      context.logs.appendLog({ level: "error", label: "client", message: `Failed to parse message: ${error}` });
    }
  });

  ws.addEventListener("close", () => {
    if (context.session.connection.ws === ws) {
      context.session.connection.ws = null;
      context.session.connection.connected = false;
      context.session.connection.capabilities.clear();
      context.controls.setControls(false);
      context.controls.setStatus("Disconnected", false);
      context.mirror.setMirrorInactive("Disconnected.");
      context.controls.clearSessionViews();
    }
  });

  ws.addEventListener("error", () => {
    if (context.session.connection.ws === ws) context.controls.setStatus("Connection Error", false);
  });
}

function disconnect() {
  context.input.releaseRemoteInput();
  if (context.session.tree.selectedId) send("select.clear");
  if (context.session.connection.ws) {
    context.session.connection.ws.close();
  }
  context.session.connection.ws = null;
  context.session.connection.connected = false;
  context.session.connection.capabilities.clear();
  context.controls.setControls(false);
  context.mirror.setMirrorInactive("Disconnected.");
  context.controls.clearSessionViews();
}

function send(type, payload = undefined, expectsResponse = true) {
  if (!context.session.connection.ws || context.session.connection.ws.readyState !== WebSocket.OPEN) return;
  const envelope = { type, payload };
  if (expectsResponse) envelope.id = context.session.connection.requestId++;
  context.session.connection.ws.send(JSON.stringify(envelope));
  return envelope.id;
}

function sendInput(payload) {
  // Input is a high-frequency notification stream; request IDs would make
  // the server emit an unnecessary acknowledgement for every pointer move.
  send("mirror.input", payload, false);
}


return { connect, disconnect, send, sendInput };
};
