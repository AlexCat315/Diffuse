InspectorModules.mirror = function(context) {
function renderMirror(payload) {
  if (!payload?.jpegBase64) return;
  context.session.mirror.mirrorActive = true;
  if (context.session.mirror.mirrorImageLoading) {
    // Keep only the newest frame while the browser decodes the current one.
    // Replacing <img>.src faster than decode can complete leaves the mirror
    // permanently black on high-DPI windows.
    context.session.mirror.pendingMirrorFrame = payload;
    return;
  }
  decodeMirrorFrame(payload, context.session.mirror.mirrorDecodeGeneration);
}

function decodeMirrorFrame(payload, generation) {
  context.session.mirror.mirrorImageLoading = true;
  const candidate = new Image();
  candidate.src = `data:image/jpeg;base64,${payload.jpegBase64}`;
  const decoded = typeof candidate.decode === "function"
    ? candidate.decode()
    : new Promise((resolve, reject) => {
        candidate.onload = resolve;
        candidate.onerror = reject;
      });
  decoded.then(() => {
    if (generation !== context.session.mirror.mirrorDecodeGeneration || !context.session.mirror.mirrorActive) return;
    context.session.mirror.mirrorFrame = payload;
    context.elements.mirror.mirrorImage.src = candidate.src;
    context.elements.mirror.mirror.classList.add("hasFrame");
    context.elements.mirror.mirrorStatus.textContent = `Frame ${payload.seq ?? ""}`.trim();
    context.elements.mirror.mirrorState.textContent = "";
  }).catch((error) => {
    context.logs.appendLog({ level: "error", label: "mirror", message: `Frame decode failed: ${error}` });
  }).finally(() => {
    if (generation !== context.session.mirror.mirrorDecodeGeneration) return;
    context.session.mirror.mirrorImageLoading = false;
    const pending = context.session.mirror.pendingMirrorFrame;
    context.session.mirror.pendingMirrorFrame = null;
    if (pending && context.session.mirror.mirrorActive) decodeMirrorFrame(pending, generation);
  });
  context.controls.setControls(context.session.connection.connected);
}

function startMirror() {
  context.session.mirror.mirrorActive = true;
  context.session.mirror.mirrorFrame = null;
  context.elements.mirror.mirrorImage.removeAttribute("src");
  context.elements.mirror.mirror.classList.remove("hasFrame");
  setMirrorWaiting();
  context.connection.send("mirror.start", {
    fps: context.format.clamp(Number(context.elements.mirror.mirrorFPS.value), 1, 60, 15),
    quality: context.format.clamp(Number(context.elements.mirror.mirrorQuality.value), 0.1, 1, 0.75),
  });
}

function stopMirror() {
  context.input.releaseRemoteInput();
  context.connection.send("mirror.stop");
  setMirrorInactive("Stopping...");
}

function setMirrorWaiting() {
  context.session.mirror.mirrorActive = true;
  context.elements.mirror.mirror.classList.remove("hasFrame");
  context.elements.mirror.mirrorStatus.textContent = "Waiting";
  context.elements.mirror.mirrorState.textContent = "Mirror requested. Waiting for the first frame...";
  context.controls.setControls(context.session.connection.connected);
}

function setMirrorInactive(message) {
  context.input.releaseRemoteInput();
  context.session.mirror.mirrorDecodeGeneration += 1;
  context.session.mirror.mirrorActive = false;
  context.session.mirror.mirrorFrame = null;
  context.session.mirror.mirrorImageLoading = false;
  context.session.mirror.pendingMirrorFrame = null;
  context.session.input.pointerDown = false;
  context.elements.mirror.mirror.classList.remove("hasFrame");
  context.elements.mirror.mirrorImage.removeAttribute("src");
  context.elements.mirror.mirrorStatus.textContent = context.session.connection.connected ? "Idle" : "Off";
  context.elements.mirror.mirrorState.textContent = message || "No mirror frame. Click Start after connecting.";
  context.controls.setControls(context.session.connection.connected);
}


return { renderMirror, decodeMirrorFrame, startMirror, stopMirror, setMirrorWaiting, setMirrorInactive };
};
