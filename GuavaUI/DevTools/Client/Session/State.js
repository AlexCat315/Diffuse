const session = {
  connection: { ws: null, requestId: 1, connected: false, capabilities: new Set() },
  tree: { tree: null, treeRenderFrame: null, snapshot: null, selectedId: null, pendingSelectionId: null, treeQuery: "", inspection: null },
  mirror: { mirrorActive: false, mirrorFrame: null, mirrorImageLoading: false, pendingMirrorFrame: null, mirrorDecodeGeneration: 0 },
  input: { pointerDown: false, pointerButton: 0, lastPointer: null, pressedKeys: new Map() },
  logs: { logEntries: [] },
  timing: { timingFrames: [] },
  checkpoint: { recording: false },
};
