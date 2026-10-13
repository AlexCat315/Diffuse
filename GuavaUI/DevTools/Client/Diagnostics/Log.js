InspectorModules.logs = function(context) {
function appendLog(entry) {
  if (!entry) return;
  context.session.logs.logEntries.push(entry);
  if (context.session.logs.logEntries.length > 250) {
    context.session.logs.logEntries.splice(0, context.session.logs.logEntries.length - 250);
  }
  renderLog();
}

function renderLog() {
  context.elements.logs.log.innerHTML = "";
  const minimum = context.format.logLevelRank(context.elements.logs.logLevel.value);
  const query = context.elements.logs.logSearch.value.trim().toLocaleLowerCase();
  const entries = context.session.logs.logEntries.filter((entry) => {
    if (context.format.logLevelRank(entry.level) < minimum) return false;
    if (!query) return true;
    return `${entry.label ?? ""} ${entry.message ?? ""} ${entry.source ?? ""}`
      .toLocaleLowerCase().includes(query);
  });
  context.elements.logs.logCount.textContent = `${entries.length}/${context.session.logs.logEntries.length}`;
  if (entries.length === 0) {
    context.elements.logs.log.className = "log empty";
    context.elements.logs.log.textContent = context.session.logs.logEntries.length === 0 ? "No log entries." : "No log entries match the filters.";
    return;
  }
  context.elements.logs.log.className = "log";
  for (const entry of entries.slice(-250)) {
    const row = document.createElement("div");
    row.className = `logEntry ${context.format.escapeClass(entry.level ?? "info")}`;
    row.innerHTML = `<span class="level">${context.format.escapeHtml(entry.level ?? "info")}</span>` +
      `<span>${context.format.escapeHtml(entry.label ?? "log")}: ${context.format.escapeHtml(entry.message ?? "")}</span>`;
    context.elements.logs.log.appendChild(row);
  }
  context.elements.logs.log.scrollTop = context.elements.logs.log.scrollHeight;
}


return { appendLog, renderLog };
};
