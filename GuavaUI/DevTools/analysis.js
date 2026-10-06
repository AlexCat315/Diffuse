// Source links are client-side editor URLs. The host never opens files or
// executes a command, and state values are never included in profiling causes.
const analysisEl = id => document.getElementById(id);
const milliseconds = value => `${Number(value || 0).toFixed(3)} ms`;

function nodeAncestry(target, node = state.tree, parents = []) {
  if (!node) return [];
  const path = [...parents, node];
  if (nodeId(node) === target || node.id === target) return path;
  for (const child of node.children ?? []) {
    const found = nodeAncestry(target, child, path);
    if (found.length) return found;
  }
  return [];
}
function sourceForNode(node) {
  if (!node) return null;
  return nodeAncestry(nodeId(node)).reverse().find(n => n.source) ?? null;
}
function normalizedSourcePath(value) {
  if (typeof value !== "string" || /[\x00-\x1f\x7f]/.test(value)) return null;
  let path = value.replaceAll("\\", "/");
  if (path !== "/" && !/^[A-Za-z]:\/$/.test(path)) path = path.replace(/\/+$/, "");
  if (!path.startsWith("/") && !/^[A-Za-z]:\//.test(path)) return null;
  if (path.split("/").some(part => part === ".." || part === ".")) return null;
  return path || "/";
}
function editorSourceURL(source, editor, buildRoot = "", localRoot = "") {
  if (!["vscode", "cursor"].includes(editor) || !source ||
      !Number.isSafeInteger(source.line) || source.line < 1 || source.line > 2147483647 ||
      !Number.isSafeInteger(source.column) || source.column < 1 || source.column > 2147483647) return null;
  let path = normalizedSourcePath(source.filePath);
  if (!path) return null;
  if (buildRoot || localRoot) {
    const build = normalizedSourcePath(buildRoot), local = normalizedSourcePath(localRoot);
    if (!build || !local) return null;
    const prefix = build.endsWith("/") ? build : build + "/";
    if (path !== build && !path.startsWith(prefix)) return null;
    path = path === build ? local : local.replace(/\/$/, "") + "/" + path.slice(prefix.length);
  }
  const encoded = path.split("/").map((part, i) => i === 0 && /^[A-Za-z]:$/.test(part) ? part : encodeURIComponent(part)).join("/");
  return `${editor}://file${encoded.startsWith("/") ? "" : "/"}${encoded}:${source.line}:${source.column}`;
}
function renderSourceAnalysis(node) {
  const sourceNode = sourceForNode(node), source = sourceNode?.source;
  const label = analysisEl("sourceLocation"), link = analysisEl("openSource");
  label.textContent = source ? `${source.fileID}:${source.line}:${source.column}${sourceNode !== node ? " (ancestor source)" : ""}`
    : node ? "No source coordinates for this node." : "Select a component to locate its source.";
  label.title = source?.filePath ?? "";
  const url = editorSourceURL(source, analysisEl("sourceEditor").value,
    analysisEl("sourceBuildRoot").value.trim(), analysisEl("sourceLocalRoot").value.trim());
  if (url) link.href = url; else link.removeAttribute("href");
  link.setAttribute("aria-disabled", String(!url));
  link.title = url ?? "Select source coordinates and provide valid absolute path prefixes, if needed.";
  const owner = node?.ownerScopeID ? findNode(state.tree, node.ownerScopeID) : null;
  const metrics = owner?.recomposition, button = analysisEl("recompositionOwner");
  button.hidden = !owner;
  button.textContent = owner ? `Component: ${compactTag(owner.viewTag) || nodeId(owner)}` : "";
  button.onclick = owner ? () => selectNode(owner) : null;
  analysisEl("recompositionStats").textContent = metrics
    ? `Recompositions: ${metrics.count}\nLast: ${milliseconds(metrics.lastMs)} · Average: ${milliseconds(metrics.count ? metrics.totalMs / metrics.count : 0)}\nTotal: ${milliseconds(metrics.totalMs)} · Max: ${milliseconds(metrics.maxMs)}\nInitial mount: ${milliseconds(metrics.initialMs)}`
    : node ? "No user-component body at this node. Select a component with profiling enabled." : "No component selected.";
  const causes = analysisEl("recompositionReasons"); causes.replaceChildren();
  if (metrics) {
    const heading = document.createElement("span");
    heading.textContent = metrics.count ? "Last trigger(s): " : "No recomposition since mount/reset.";
    causes.append(heading);
    for (const reason of metrics.reasons ?? []) {
      const row = document.createElement("div");
      row.textContent = `${reason.kind}${reason.detail ? ": " + reason.detail : ""}`;
      if (reason.originScopeID) {
        const origin = findNode(state.tree, reason.originScopeID);
        const ref = document.createElement("button"); ref.textContent = origin ? compactTag(origin.viewTag) : `scope ${reason.originScopeID} (removed)`;
        ref.disabled = !origin; ref.onclick = () => selectNode(origin); row.append(" ← ", ref);
      }
      causes.append(row);
    }
  }
  analysisEl("resetRecomposition").disabled = !state.connected || !hasCapability("recomposition");
}
function renderRecompositionTable() {
  const nodes = [];
  function collect(node) {
    if (!node) return;
    if (node.recomposition) nodes.push(node);
    for (const child of node.children ?? []) collect(child);
  }
  collect(state.tree);
  const sort = analysisEl("recompositionSort").value;
  nodes.sort((a, b) => b.recomposition[sort] - a.recomposition[sort]);
  analysisEl("recompositionCount").textContent = String(nodes.length);
  const table = analysisEl("recompositionTable"); table.replaceChildren();
  for (const node of nodes.slice(0, 100)) {
    const row = document.createElement("button"); row.className = "recompositionRow";
    const name = document.createElement("span"), stats = document.createElement("span");
    name.textContent = compactTag(node.viewTag) || nodeId(node); name.title = node.viewTag ?? "";
    stats.textContent = `${node.recomposition.count} × · ${milliseconds(node.recomposition[sort === "count" ? "totalMs" : sort])}`;
    row.append(name, stats); row.onclick = () => selectNode(node); table.append(row);
  }
  if (nodes.length > 100) table.append(`Showing the first 100 of ${nodes.length} components.`);
}
document.addEventListener("DOMContentLoaded", () => {
  for (const id of ["sourceEditor", "sourceBuildRoot", "sourceLocalRoot"]) {
    const field = analysisEl(id);
    try { field.value = localStorage.getItem("guava.inspector." + id) ?? field.value; } catch {}
    field.addEventListener(id === "sourceEditor" ? "change" : "input", () => {
      try { localStorage.setItem("guava.inspector." + id, field.value); } catch {}
      renderSourceAnalysis(findNode(state.tree, state.selectedId));
    });
  }
  analysisEl("recompositionSort").addEventListener("change", renderRecompositionTable);
  analysisEl("resetRecomposition").addEventListener("click", () => send("inspect.recomposition.reset"));
  renderSourceAnalysis(null); renderRecompositionTable();
});
