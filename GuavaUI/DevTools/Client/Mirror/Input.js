InspectorModules.input = function(context) {
function installMirrorInput() {
  context.elements.mirror.mirror.addEventListener("pointermove", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    context.session.input.lastPointer = point;
    if (context.session.tree.inspection?.picking) { context.connection.send("inspect.hover", point, false); return; }
    const scale = mirrorScale();
    context.connection.sendInput({
      kind: "pointerMove",
      x: point.x,
      y: point.y,
      deltaX: (event.movementX || 0) * scale.x,
      deltaY: (event.movementY || 0) * scale.y,
      modifiers: modifiers(event),
    });
  });

  context.elements.mirror.mirror.addEventListener("pointerdown", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    if (context.session.tree.inspection?.picking) {
      state.pickedPointer = event.pointerId;
      context.connection.send("inspect.pick", point); event.preventDefault(); return;
    }
    context.session.input.pointerDown = true;
    context.session.input.pointerButton = event.button;
    context.session.input.lastPointer = point;
    context.elements.mirror.mirror.setPointerCapture?.(event.pointerId);
    context.elements.mirror.mirror.focus?.();
    context.connection.sendInput({
      kind: "pointerDown",
      x: point.x,
      y: point.y,
      button: event.button,
      clickCount: event.detail || 1,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  });

  context.elements.mirror.mirror.addEventListener("pointerup", (event) => {
    if (state.pickedPointer === event.pointerId) { state.pickedPointer = null; event.preventDefault(); return; }
    const point = mirrorPoint(event);
    if (!point && !context.session.input.lastPointer) return;
    context.session.input.pointerDown = false;
    context.connection.sendInput({
      kind: "pointerUp",
      x: (point ?? context.session.input.lastPointer).x,
      y: (point ?? context.session.input.lastPointer).y,
      button: event.button,
      clickCount: event.detail || 1,
      modifiers: modifiers(event),
    });
    event.preventDefault();
  });

  context.elements.mirror.mirror.addEventListener("pointercancel", releasePointer);

  context.elements.mirror.mirror.addEventListener("wheel", (event) => {
    const point = mirrorPoint(event);
    if (!point) return;
    const scale = mirrorScale();
    context.connection.sendInput({
      kind: "wheel",
      x: point.x,
      y: point.y,
      deltaX: -event.deltaX * (event.deltaMode === 0 ? scale.x : 1),
      deltaY: -event.deltaY * (event.deltaMode === 0 ? scale.y : 1),
      scroll: {
        unit: ["points", "lines", "pages"][event.deltaMode] || "points",
        device: "unknown", phase: "none", momentumPhase: "none",
        timestamp: event.timeStamp / 1000,
      },
      modifiers: modifiers(event),
    });
    event.preventDefault();
  }, { passive: false });

  context.elements.mirror.mirror.addEventListener("keydown", (event) => {
    if (!context.session.connection.connected) return;
    if (context.session.tree.inspection?.picking) { if (event.code === "Escape") context.connection.send("inspect.pick.stop"); event.preventDefault(); return; }
    if (event.code) context.session.input.pressedKeys.set(event.code, keyCode(event));
    context.connection.sendInput({
      kind: "keyDown",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    if (isTextKey(event)) {
      context.connection.sendInput({
        kind: "text",
        text: event.key,
      });
    }
    event.preventDefault();
  });

  context.elements.mirror.mirror.addEventListener("keyup", (event) => {
    if (!context.session.connection.connected) return;
    context.connection.sendInput({
      kind: "keyUp",
      key: event.code,
      keyCode: keyCode(event),
      modifiers: modifiers(event),
      isRepeat: event.repeat,
    });
    context.session.input.pressedKeys.delete(event.code);
    event.preventDefault();
  });

  context.elements.mirror.mirror.addEventListener("blur", releaseRemoteInput);
}

function mirrorPoint(event) {
  if (!context.session.connection.connected || !context.session.mirror.mirrorFrame) return null;
  const rect = context.elements.mirror.mirrorImage.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return null;
  const localX = event.clientX - rect.left;
  const localY = event.clientY - rect.top;
  if (localX < 0 || localY < 0 || localX > rect.width || localY > rect.height) {
    return null;
  }
  return {
    x: (localX / rect.width) * context.session.mirror.mirrorFrame.logicalWidth,
    y: (localY / rect.height) * context.session.mirror.mirrorFrame.logicalHeight,
  };
}

function mirrorScale() {
  const rect = context.elements.mirror.mirrorImage.getBoundingClientRect();
  if (!context.session.mirror.mirrorFrame || rect.width <= 0 || rect.height <= 0) return { x: 1, y: 1 };
  return {
    x: context.session.mirror.mirrorFrame.logicalWidth / rect.width,
    y: context.session.mirror.mirrorFrame.logicalHeight / rect.height,
  };
}

function releasePointer(event) {
  if (!context.session.input.pointerDown) return;
  const point = (event && mirrorPoint(event)) || context.session.input.lastPointer || { x: 0, y: 0 };
  context.connection.sendInput({
    kind: "pointerUp",
    x: point.x,
    y: point.y,
    button: context.session.input.pointerButton,
    clickCount: 1,
    modifiers: event ? modifiers(event) : 0,
  });
  context.session.input.pointerDown = false;
}

function releaseRemoteInput() {
  releasePointer();
  for (const [code, codePoint] of context.session.input.pressedKeys) {
    context.connection.sendInput({
      kind: "keyUp",
      key: code,
      keyCode: codePoint,
      modifiers: 0,
      isRepeat: false,
    });
  }
  context.session.input.pressedKeys.clear();
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


return { installMirrorInput, mirrorPoint, mirrorScale, releasePointer, releaseRemoteInput, modifiers, keyCode, isTextKey };
};
