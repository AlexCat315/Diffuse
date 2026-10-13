InspectorModules.checkpoint = function(context) {
function restoreState() {
  let snapshot;
  try {
    snapshot = JSON.parse(context.elements.checkpoint.stateSnapshot.value || "{}");
  } catch (error) {
    context.logs.appendLog({ level: "error", label: "state", message: `Invalid JSON: ${error.message}` });
    return;
  }
  const valid = snapshot && !Array.isArray(snapshot) && typeof snapshot === "object" &&
    Object.values(snapshot).every((value) => typeof value === "string");
  if (!valid) {
    context.logs.appendLog({ level: "error", label: "state", message: "Checkpoint must be an object with string values." });
    return;
  }
  context.connection.send("state.restore", snapshot);
}

function sendJSON(type, text) {
  try { context.connection.send(type, JSON.parse(text)); }
  catch (error) { context.logs.appendLog({level:"error", label:"client", message:String(error)}); }
}

return { restoreState, sendJSON };
};
