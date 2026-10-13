InspectorModules.timing = function(context) {
function renderTiming(payload) {
  if (!payload) return;
  context.session.timing.timingFrames.push(payload);
  if (context.session.timing.timingFrames.length > 120) context.session.timing.timingFrames.shift();
  const recent = context.session.timing.timingFrames.slice(-60);
  const average = (key) => recent.reduce((sum, frame) => sum + context.format.finiteNumber(frame[key]), 0) / recent.length;
  const totalMs = context.format.finiteNumber(payload.totalMs);
  context.elements.timing.timing.className = "details";
  context.elements.timing.timing.textContent = JSON.stringify({
    frame: payload.frame,
    presentation: payload.presented == null ? "unknown" : payload.presented ? "submitted" : "skipped",
    // Reciprocal CPU work time is a throughput estimate, not observed display FPS.
    cpuThroughputFPS: totalMs > 0 ? context.format.round(1000 / totalMs, 1) : null,
    currentMs: {
      recomposition: payload.recompositionMs == null ? null : context.format.round(payload.recompositionMs),
      layout: context.format.round(payload.layoutMs),
      draw: context.format.round(payload.drawMs),
      present: context.format.round(payload.presentMs),
      total: context.format.round(payload.totalMs),
    },
    average60Ms: {
      layout: context.format.round(average("layoutMs")),
      draw: context.format.round(average("drawMs")),
      present: context.format.round(average("presentMs")),
      total: context.format.round(average("totalMs")),
    },
    nodes: payload.nodeCount,
    batches: payload.batchCount,
  }, null, 2);
}


return { renderTiming };
};
