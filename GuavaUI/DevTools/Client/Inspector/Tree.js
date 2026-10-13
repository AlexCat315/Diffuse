InspectorModules.tree = function(context) {
function renderTree() {
  context.elements.tree.tree.innerHTML = "";
  if (!context.session.tree.tree) {
    context.elements.tree.tree.className = "tree empty";
    context.elements.tree.tree.textContent = "No root node.";
    context.elements.tree.treeCount.textContent = "";
    renderDetails(null);
    return;
  }
  context.elements.tree.tree.className = "tree";
  const total = countTreeNodes(context.session.tree.tree);
  const shown = renderNode(context.elements.tree.tree, context.session.tree.tree, 0);
  context.elements.tree.treeCount.textContent = context.session.tree.treeQuery ? `${shown}/${total}` : String(total);
  if (shown === 0) {
    context.elements.tree.tree.className = "tree empty";
    context.elements.tree.tree.textContent = "No nodes match the current filter.";
  }
}

function renderNode(parent, node, depth) {
  if (context.session.tree.treeQuery && !treeContainsQuery(node, context.session.tree.treeQuery)) return 0;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "treeNode" + (nodeId(node) === context.session.tree.selectedId ? " selected" : "");
  button.style.paddingLeft = `${6 + depth * 14}px`;
  button.innerHTML = `<span class="nodeLabel">${context.format.escapeHtml(nodeLabel(node))}</span>` +
    `<span class="nodeMuted">${context.format.escapeHtml(nodeBadge(node))}</span>`;
  button.addEventListener("click", () => selectNode(node));
  parent.appendChild(button);

  let count = 1;
  for (const child of node.children ?? []) {
    count += renderNode(parent, child, depth + 1);
  }
  return count;
}

function selectNode(node) {
  context.session.tree.selectedId = nodeId(node);
  context.session.tree.pendingSelectionId = context.session.tree.selectedId;
  context.connection.send("select.node", { id: context.session.tree.selectedId });
  renderTree();
  renderDetails(node);
}

function renderDetails(node) {
  context.inspection.renderInspection(node);
  context.analysis.renderSourceAnalysis(node);
  context.observation.renderStateRegistry();
  context.observation.observationControls();
  if (!node) {
    context.elements.tree.details.className = "details empty";
    context.elements.tree.details.textContent = "Select a node in the tree.";
    return;
  }
  context.elements.tree.details.className = "details";
  context.elements.tree.details.textContent = JSON.stringify({
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

function nodeId(node) {
  return node.elementID ?? node.id;
}

function syncSelection() {
  if (!context.session.tree.selectedId) return;
  const selected = findNode(context.session.tree.tree, context.session.tree.selectedId);
  if (selected) {
    renderDetails(selected);
  } else {
    context.session.tree.selectedId = null;
    context.session.tree.pendingSelectionId = null;
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
  const parts = String(tag).split("<", 1)[0].split(".");
  return parts[parts.length - 1];
}


return { renderTree, renderNode, selectNode, renderDetails, nodeId, syncSelection, findNode, countTreeNodes, treeContainsQuery, nodeLabel, nodeBadge, compactTag };
};
