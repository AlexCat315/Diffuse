InspectorModules.inspection = function(context) {
// Shared Inspector for socket and in-browser hosts. All values come from the
// live scene; temporary changes are owned by the host, never by DOM styles.
let inspectionNodeID = null;
let styleTimer;
const inspectEl = id => document.getElementById(id);
const paddingEdges = ["top", "right", "bottom", "left"];
const paddingInput = edge => inspectEl("padding" + edge[0].toUpperCase() + edge.slice(1));

function inspectionMessage(message, error = false) {
  inspectEl("styleMessage").textContent = message;
  inspectEl("styleMessage").classList.toggle("error", error);
}
function inspectionControls() {
  const live = context.session.connection.connected;
  const node = context.tree.findNode(context.session.tree.tree, context.session.tree.selectedId);
  const editing = live && context.controls.hasCapability("style");
  const info = context.session.tree.inspection;
  inspectEl("pickNode").disabled = !live || !context.controls.hasCapability("inspect");
  inspectEl("pickNode").textContent = info?.picking ? "Cancel picking (Esc)" : "Pick component";
  inspectEl("pickNode").setAttribute("aria-pressed", String(!!info?.picking));
  inspectEl("undoStyle").disabled = !editing || !info?.canUndo;
  inspectEl("redoStyle").disabled = !editing || !info?.canRedo;
  inspectEl("clearStyle").disabled = !editing || !node?.style?.overrides?.length;
  inspectEl("clearAllStyles").disabled = !editing || !info?.overrideCount;
  inspectEl("styleFields").disabled = !editing || !node;
  for (const edge of paddingEdges) paddingInput(edge).disabled = !node?.layout;
  inspectEl("resetPadding").disabled = !node?.layout;
  inspectEl("overrideStatus").textContent = !live ? "Temporary styles · disconnected"
    : !context.controls.hasCapability("style") ? "This host does not expose editable styles"
    : `${info?.overrideCount ?? 0} node(s) overridden · ${node?.style?.overrides?.join(", ") || "selected node uses app styles"}`;
}
function syncInspection(info) {
  if (!info) return;
  context.session.tree.inspection = info;
  if (context.session.tree.pendingSelectionId === info.selectedID) context.session.tree.pendingSelectionId = null;
  if (!context.session.tree.pendingSelectionId) context.session.tree.selectedId = info.selectedID ?? null;
  inspectionControls();
  context.tree.renderTree();
  context.tree.renderDetails(context.tree.findNode(context.session.tree.tree, context.session.tree.selectedId));
}
function renderInspection(node) {
  const id = node ? context.tree.nodeId(node) : null;
  const changed = id !== inspectionNodeID;
  if (changed) {
    clearTimeout(styleTimer); inspectionMessage("");
    document.querySelector(".detailsPane").scrollTop = 0;
  }
  inspectionNodeID = id;
  const path = inspectEl("selectionPath"); path.replaceChildren();
  function ancestry(n, parents = []) {
    if (!n) return null;
    if (context.tree.nodeId(n) === id) return [...parents, n];
    for (const child of n.children ?? []) { const found = ancestry(child, [...parents, n]); if (found) return found; }
  }
  for (const n of ancestry(context.session.tree.tree) ?? []) {
    const button = document.createElement("button"); button.textContent = n.debugName || context.tree.compactTag(n.viewTag) || context.tree.nodeId(n);
    button.title = "Select " + button.textContent; button.addEventListener("click", () => context.tree.selectNode(n)); path.append(button);
  }
  const model = inspectEl("boxModel");
  if (node?.layout) {
    const l = node.layout;
    const edges = inset => paddingEdges.map(e => `${e}: ${context.format.round(inset[e])}`).join(" · ");
    model.className = "boxModel";
    // Numeric host data only; labels and breadcrumbs use textContent.
    model.innerHTML = `<div class="boxMargin">margin <span>${edges(l.margin)}</span>
      <div class="boxBorder">border <span>${edges(l.border)}</span>
        <div class="boxPadding">padding <span>${edges(l.padding)}</span>
          <div class="boxContent">content ${context.format.round(l.contentWidth)} × ${context.format.round(l.contentHeight)}</div>
        </div>
      </div>
    </div>`;
    inspectEl("layoutFacts").textContent = `${context.format.round(node.absoluteFrame?.w ?? node.frame.w)} × ${context.format.round(node.absoluteFrame?.h ?? node.frame.h)} pt · ${l.flexDirection} · align ${l.alignItems} · justify ${l.justifyContent} · grow ${l.flexGrow} / shrink ${l.flexShrink}`;
  } else {
    model.className = "boxModel empty";
    model.textContent = node ? "Composition anchor: select a child to inspect its layout box." : "Select a component in the app or tree.";
    inspectEl("layoutFacts").textContent = "";
  }
  function set(input, value) { if (changed || document.activeElement !== input) input.value = value; }
  for (const edge of paddingEdges) set(paddingInput(edge), node?.layout ? context.format.round(node.layout.padding[edge]) : "");
  for (const name of ["background", "foreground"]) {
    const value = node?.style?.[name + "Color"] ?? "";
    set(inspectEl(name + "Color"), value);
    set(inspectEl(name + "Swatch"), value.slice(0, 7) || "#000000");
  }
  inspectionControls();
}
function editProperties(properties) {
  if (!context.session.tree.selectedId || !context.session.connection.connected) return;
  inspectionMessage("Temporary override applied. Clear to restore app styles.");
  context.connection.send("inspect.style.set", {id: context.session.tree.selectedId, properties});
}
function editPadding() {
  const values = Object.fromEntries(paddingEdges.map(edge => [edge, Number(paddingInput(edge).value)]));
  if (paddingEdges.some(edge => paddingInput(edge).value === "") ||
      Object.values(values).some(v => !Number.isFinite(v) || v < 0 || v > 4096)) {
    inspectionMessage("Padding must be between 0 and 4096 points.", true); return;
  }
  editProperties({padding: values});
}
function editColor(name) {
  const value = inspectEl(name).value.trim();
  if (value && !/^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(value)) {
    inspectionMessage("Use #RRGGBB or #RRGGBBAA. Empty removes the override.", true); return;
  }
  editProperties({[name]: value || null});
}
document.addEventListener("DOMContentLoaded", () => {
  inspectEl("pickNode").addEventListener("click", () => {
    context.session.tree.pendingSelectionId = null;
    context.connection.send(context.session.tree.inspection?.picking ? "inspect.pick.stop" : "inspect.pick.start");
    inspectionMessage("Click a component in the app or mirror. Escape cancels.");
  });
  for (const [id, command] of [["undoStyle", "undo"], ["redoStyle", "redo"], ["clearStyle", "clear"], ["clearAllStyles", "clearAll"]]) {
    inspectEl(id).addEventListener("click", () => {
      clearTimeout(styleTimer);
      context.connection.send("inspect.style." + command, command === "clear" ? {id: context.session.tree.selectedId} : undefined);
      inspectionMessage("Temporary styles updated.");
    });
  }
  for (const input of paddingEdges.map(paddingInput)) {
    input.addEventListener("input", () => { clearTimeout(styleTimer); styleTimer = setTimeout(editPadding, 120); });
    input.addEventListener("change", () => { clearTimeout(styleTimer); editPadding(); });
  }
  for (const name of ["background", "foreground"]) {
    const text = inspectEl(name + "Color"), swatch = inspectEl(name + "Swatch");
    text.addEventListener("input", () => { clearTimeout(styleTimer); styleTimer = setTimeout(() => editColor(name + "Color"), 120); });
    text.addEventListener("change", () => { clearTimeout(styleTimer); editColor(name + "Color"); });
    swatch.addEventListener("input", () => { text.value = swatch.value; editColor(name + "Color"); });
    inspectEl("reset" + name[0].toUpperCase() + name.slice(1)).addEventListener("click", () => editProperties({[name + "Color"]: null}));
  }
  inspectEl("resetPadding").addEventListener("click", () => editProperties({padding: null}));
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && context.session.tree.inspection?.picking) { context.connection.send("inspect.pick.stop"); event.preventDefault(); }
  });
  inspectionControls();
});

return { inspectionMessage, inspectionControls, syncInspection, renderInspection, editProperties, editPadding, editColor };
};
