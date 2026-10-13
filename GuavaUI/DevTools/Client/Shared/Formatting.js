InspectorModules.format = function(context) {
function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeClass(value) {
  return String(value).replace(/[^a-z0-9_-]/gi, "");
}

function finiteNumber(value) {
  return Number.isFinite(Number(value)) ? Number(value) : 0;
}

function round(value, digits = 2) {
  const factor = 10 ** digits;
  return Math.round(finiteNumber(value) * factor) / factor;
}

function clamp(value, minimum, maximum, fallback) {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(minimum, value));
}

function logLevelRank(level) {
  return ({ trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 })[level] ?? 2;
}


return { escapeHtml, escapeClass, finiteNumber, round, clamp, logLevelRank };
};
