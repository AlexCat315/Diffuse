InspectorModules.runtime = function(context) {
function renderRuntime(snapshot) {
  if (!snapshot) {
    context.elements.tree.runtime.className = "details empty";
    context.elements.tree.runtime.textContent = "No tree snapshot.";
    return;
  }
  const invalidations = snapshot.invalidations ?? [];
  const tail = invalidations.slice(-8).map((entry) => ({
    target: entry.target,
    phase: entry.phase,
    source: entry.source,
  }));
  context.elements.tree.runtime.className = "details";
  context.elements.tree.runtime.textContent = JSON.stringify({
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


return { renderRuntime, summarizeInputInventory };
};
