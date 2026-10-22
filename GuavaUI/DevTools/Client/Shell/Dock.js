InspectorModules.dock = function(context) {
// Bottom dock: tab switching, drag-resize and collapse. Preferences persist in
// this browser so the two-zone layout reopens as the user left it.
const dock = document.querySelector(".dock");
const tabs = [...document.querySelectorAll(".dockTab")];
const panels = [...document.querySelectorAll(".dockPanel")];
const collapseButton = document.getElementById("dockCollapse");
const splitter = document.getElementById("dockSplitter");
const MIN_HEIGHT = 140;

function readPref(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
function writePref(key, value) { try { localStorage.setItem(key, value); } catch {} }

function select(tab, { persist = true, expand = false } = {}) {
  tabs.forEach(button => button.classList.toggle("active", button.dataset.tab === tab));
  panels.forEach(panel => panel.classList.toggle("active", panel.dataset.tab === tab));
  if (expand) dock.classList.remove("collapsed");
  if (persist) writePref("guava.devtools.tab", tab);
  if (tab === "performance") context.performance?.refreshNow();
}

function setCollapsed(collapsed) {
  dock.classList.toggle("collapsed", collapsed);
  writePref("guava.devtools.dockCollapsed", collapsed ? "1" : "0");
}

function init() {
  const savedHeight = Number(readPref("guava.devtools.dockHeight", ""));
  if (Number.isFinite(savedHeight) && savedHeight >= MIN_HEIGHT) {
    dock.style.setProperty("--dock-height", `${savedHeight}px`);
  }
  const savedTab = readPref("guava.devtools.tab", "tree");
  if (tabs.some(tab => tab.dataset.tab === savedTab)) select(savedTab, { persist: false });
  if (readPref("guava.devtools.dockCollapsed", "0") === "1") setCollapsed(true);
}

tabs.forEach(button => button.addEventListener("click", () => {
  const tab = button.dataset.tab;
  const wasActive = button.classList.contains("active");
  // Clicking the active tab collapses; clicking any tab restores the dock.
  if (wasActive && !dock.classList.contains("collapsed")) setCollapsed(true);
  else select(tab, { expand: true });
}));

collapseButton.addEventListener("click", () => setCollapsed(!dock.classList.contains("collapsed")));

let dragging = false;
let startY = 0;
let startHeight = 0;
splitter.addEventListener("pointerdown", event => {
  if (dock.classList.contains("collapsed")) return;
  dragging = true;
  startY = event.clientY;
  startHeight = dock.getBoundingClientRect().height;
  splitter.setPointerCapture(event.pointerId);
  event.preventDefault();
});
splitter.addEventListener("pointermove", event => {
  if (!dragging) return;
  const max = window.innerHeight - 96;
  const height = Math.min(max, Math.max(MIN_HEIGHT, startHeight + (startY - event.clientY)));
  dock.style.setProperty("--dock-height", `${height}px`);
});
function finishDrag() {
  if (!dragging) return;
  dragging = false;
  writePref("guava.devtools.dockHeight", String(Math.round(dock.getBoundingClientRect().height)));
}
splitter.addEventListener("pointerup", finishDrag);
splitter.addEventListener("pointercancel", finishDrag);

document.addEventListener("DOMContentLoaded", init);

return { select, setCollapsed };
};
