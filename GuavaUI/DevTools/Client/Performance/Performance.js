InspectorModules.performance = function(context) {
// Continuous performance capture: timing frames are streamed automatically on
// connect; the CPU timeline is opt-in via "Auto trace". Everything is derived
// in the browser and can be exported as a Markdown/JSON report for AI review.
const MAX_FRAMES = 3600;
const HEAT_BUCKETS = 120;
const FRAME_BUDGET_MS = 1000 / 60;
const STAGES = [
  { key: "totalMs", name: "Frame total", budget: FRAME_BUDGET_MS },
  { key: "recompositionMs", name: "Recomposition", budget: 4, optional: true },
  { key: "layoutMs", name: "Layout", budget: 5 },
  { key: "drawMs", name: "Draw", budget: 6 },
  { key: "presentMs", name: "Present", budget: 8 },
];

const perf = context.session.performance = {
  frames: [],
  markers: [],
  connectedAt: null,
  autoTrace: readPref("guava.devtools.autoTrace", true),
  timer: null,
};

function el(id) { return document.getElementById(id); }
function readPref(key, fallback) {
  try { const value = localStorage.getItem(key); return value == null ? fallback : value === "1"; }
  catch { return fallback; }
}
function writePref(key, value) { try { localStorage.setItem(key, value ? "1" : "0"); } catch {} }
function finite(value) { return context.format.finiteNumber(value); }
function round(value, digits = 2) { return context.format.round(value, digits); }

function isPerformanceTab() {
  return document.querySelector(".dockTab[data-tab='performance']")?.classList.contains("active") === true;
}

function setConnected(connected) {
  if (connected) {
    perf.connectedAt = Date.now();
    if (perf.timer == null) perf.timer = setInterval(() => { if (isPerformanceTab()) render(); }, 1000);
  } else if (perf.timer != null) {
    clearInterval(perf.timer);
    perf.timer = null;
  }
  updateControls();
}

function reset() {
  perf.frames = [];
  perf.markers = [];
  perf.connectedAt = null;
  render();
  updateControls();
}

function recordFrame(payload) {
  if (!payload) return;
  const now = performance.now();
  perf.frames.push({
    t: now,
    wall: Date.now(),
    frame: payload.frame,
    totalMs: finite(payload.totalMs),
    recompositionMs: payload.recompositionMs == null ? null : finite(payload.recompositionMs),
    layoutMs: finite(payload.layoutMs),
    drawMs: finite(payload.drawMs),
    presentMs: finite(payload.presentMs),
    presented: payload.presented == null ? null : Boolean(payload.presented),
    nodeCount: finite(payload.nodeCount),
    batchCount: finite(payload.batchCount),
  });
  if (perf.frames.length > MAX_FRAMES) perf.frames.splice(0, perf.frames.length - MAX_FRAMES);
}

function framesInWindow() {
  const value = el("perfWindow").value;
  if (value === "all") return perf.frames;
  const cutoff = performance.now() - Number(value) * 1000;
  return perf.frames.filter(frame => frame.t >= cutoff);
}

function sortedValues(frames, key) {
  return frames.map(frame => frame[key]).filter(value => value != null).sort((a, b) => a - b);
}

function quantile(sorted, q) {
  if (!sorted.length) return null;
  const index = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * q));
  return sorted[index];
}

function average(values) {
  if (!values.length) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function stageStats(frames, stage) {
  const values = sortedValues(frames, stage.key);
  if (!values.length) return null;
  const over = values.filter(value => value > stage.budget).length;
  return {
    key: stage.key,
    name: stage.name,
    budget: stage.budget,
    average: average(values),
    p50: quantile(values, 0.5),
    p95: quantile(values, 0.95),
    p99: quantile(values, 0.99),
    max: values[values.length - 1],
    overPercent: over / values.length * 100,
  };
}

function heatColor(value, budget) {
  const intensity = Math.max(0, Math.min(1.25, value / budget));
  if (intensity <= 0.001) return "rgba(255,255,255,0.05)";
  let rgb;
  if (intensity < 0.5) rgb = "110,205,126";
  else if (intensity < 0.85) rgb = "229,189,104";
  else rgb = "245,110,110";
  return `rgba(${rgb},${(0.22 + intensity * 0.62).toFixed(3)})`;
}

function buildReport() {
  const frames = framesInWindow();
  const stages = STAGES
    .filter(stage => stage.optional !== true || frames.some(frame => frame[stage.key] != null))
    .map(stage => stageStats(frames, stage))
    .filter(Boolean);
  const totals = sortedValues(frames, "totalMs");
  const total = stageStats(frames, STAGES[0]);
  const fpsValues = frames.map(frame => frame.totalMs > 0 ? 1000 / frame.totalMs : 0);
  const presentKnown = frames.filter(frame => frame.presented != null);
  const presented = presentKnown.filter(frame => frame.presented).length;
  const hitches = frames.filter(frame => frame.totalMs > FRAME_BUDGET_MS).length;
  const severe = frames.filter(frame => frame.totalMs > 1000 / 30).length;
  const spanMs = frames.length > 1 ? frames[frames.length - 1].t - frames[0].t : 0;

  // Heatmap: bucket frames by wall time, worst frame wins per bucket.
  const activeStages = STAGES.filter(stage => stage.optional !== true || frames.some(frame => frame[stage.key] != null));
  const buckets = [];
  for (let i = 0; i < HEAT_BUCKETS; i++) buckets.push(null);
  if (frames.length) {
    const firstT = frames[0].t;
    const span = Math.max(spanMs, 1);
    for (const frame of frames) {
      const index = Math.min(HEAT_BUCKETS - 1, Math.max(0, Math.floor(((frame.t - firstT) / span) * HEAT_BUCKETS)));
      if (buckets[index] == null || frame.totalMs > buckets[index].totalMs) buckets[index] = frame;
    }
  }
  const heatmap = {
    stages: activeStages.map(stage => ({ key: stage.key, name: stage.name, budget: stage.budget })),
    buckets,
  };

  const worst = frames.slice().sort((a, b) => b.totalMs - a.totalMs).slice(0, 8);
  const hotComponents = aggregateComponents();
  const markers = perf.markers
    .filter(marker => !frames.length || marker.t >= frames[0].t - 1000)
    .map(marker => ({ label: marker.label, relativeSeconds: frames.length ? round((marker.t - frames[0].t) / 1000) : 0, wall: marker.wall }));

  return {
    generatedAt: new Date().toISOString(),
    host: context.session.connection.host ?? null,
    window: el("perfWindow").value,
    frame: {
      first: frames[0]?.frame ?? null,
      last: frames[frames.length - 1]?.frame ?? null,
      sampleCount: frames.length,
      spanSeconds: round(spanMs / 1000),
    },
    summary: {
      cpuThroughputFPS: total && fpsValues.length ? round(average(fpsValues), 1) : null,
      totalAverageMs: total?.average ?? null,
      totalP50Ms: total?.p50 ?? null,
      totalP95Ms: total?.p95 ?? null,
      totalP99Ms: total?.p99 ?? null,
      totalMaxMs: total?.max ?? null,
      hitches: hitches,
      hitchPercent: frames.length ? round(hitches / frames.length * 100, 1) : 0,
      severeHitches: severe,
      presentedPercent: presentKnown.length ? round(presented / presentKnown.length * 100, 1) : null,
      averageNodeCount: frames.length ? round(average(frames.map(frame => frame.nodeCount))) : null,
      averageBatchCount: frames.length ? round(average(frames.map(frame => frame.batchCount))) : null,
    },
    stages,
    heatmap,
    worstFrames: worst,
    hotComponents,
    markers,
    timeline: {
      recording: context.session.observation?.recording ?? false,
      eventCount: context.session.observation?.events.length ?? 0,
      dropped: context.session.observation?.dropped ?? 0,
      trace: context.session.observation?.events.length ? context.session.observation.timelineTrace() : null,
    },
    recentLogs: context.session.logs.logEntries.slice(-200),
  };
}

function aggregateComponents() {
  const events = context.session.observation?.events ?? [];
  const map = new Map();
  for (const event of events) {
    if (!event || !event.name) continue;
    const id = `${event.phase}\u0000${event.name}`;
    let entry = map.get(id);
    if (!entry) {
      entry = { phase: event.phase, name: event.name, count: 0, totalMs: 0, maxMs: 0 };
      map.set(id, entry);
    }
    entry.count += 1;
    entry.totalMs += finite(event.durationMs);
    entry.maxMs = Math.max(entry.maxMs, finite(event.durationMs));
  }
  return [...map.values()]
    .map(entry => ({ ...entry, totalMs: round(entry.totalMs, 3), averageMs: round(entry.totalMs / entry.count, 3), maxMs: round(entry.maxMs, 3) }))
    .sort((a, b) => b.totalMs - a.totalMs)
    .slice(0, 15);
}

function renderSummary(report) {
  const target = el("perfSummary");
  target.replaceChildren();
  const cards = [
    { label: "CPU throughput", value: report.summary.cpuThroughputFPS == null ? "—" : `${report.summary.cpuThroughputFPS} fps`, tone: report.summary.hitchPercent > 10 ? "bad" : report.summary.hitchPercent > 2 ? "warn" : "good" },
    { label: "avg frame", value: fmt(report.summary.totalAverageMs) },
    { label: "p95", value: fmt(report.summary.totalP95Ms), tone: report.summary.totalP95Ms > FRAME_BUDGET_MS ? "warn" : "good" },
    { label: "p99", value: fmt(report.summary.totalP99Ms), tone: report.summary.totalP99Ms > FRAME_BUDGET_MS ? "bad" : "good" },
    { label: "max", value: fmt(report.summary.totalMaxMs) },
    { label: "hitches", value: `${report.summary.hitches}`, tone: report.summary.hitchPercent > 2 ? "warn" : "good" },
    { label: "presented", value: report.summary.presentedPercent == null ? "—" : `${report.summary.presentedPercent}%` },
    { label: "nodes", value: report.summary.averageNodeCount ?? "—" },
    { label: "batches", value: report.summary.averageBatchCount ?? "—" },
    { label: "samples", value: report.frame.sampleCount },
  ];
  for (const card of cards) {
    const node = document.createElement("div");
    node.className = "perfCard";
    const value = document.createElement("span");
    value.className = `value ${card.tone ?? ""}`;
    value.textContent = card.value;
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = card.label;
    node.append(value, label);
    target.append(node);
  }
}

function fmt(value, digits = 2) {
  return value == null ? "—" : `${round(value, digits)} ms`;
}

function renderHeatmap(report) {
  const target = el("perfHeatmap");
  target.replaceChildren();
  const buckets = report.heatmap.buckets;
  if (!report.frame.sampleCount) {
    target.className = "heatmap empty";
    target.textContent = "No timing data.";
    return;
  }
  target.className = "heatmap";
  for (const stage of report.heatmap.stages) {
    const label = document.createElement("div");
    label.className = "heatRowLabel";
    label.textContent = stage.name;
    const cells = document.createElement("div");
    cells.className = "heatCells";
    cells.style.gridTemplateRows = `repeat(${report.heatmap.stages.length}, 20px)`;
    for (const frame of buckets) {
      const cell = document.createElement("div");
      cell.className = "heatCell";
      const value = frame ? frame[stage.key] : 0;
      cell.style.background = heatColor(value ?? 0, stage.budget);
      if (frame) {
        cell.title = `${stage.name}: ${round(value ?? 0, 2)} ms / budget ${stage.budget} ms\n`
          + `frame ${frame.frame} · total ${round(frame.totalMs, 2)} ms · ${new Date(frame.wall).toLocaleTimeString()}`;
      }
      cells.append(cell);
    }
    target.append(label, cells);
  }
}

function tableRow(cells, head = false) {
  const row = document.createElement("div");
  row.className = `perfTableRow${head ? " head" : ""}`;
  for (const cell of cells) {
    const node = document.createElement(head ? "span" : "span");
    node.className = `cell ${cell.tone ?? ""}${head ? " head" : ""}`;
    if (head) node.textContent = cell.label;
    else {
      node.textContent = cell.value;
      if (cell.title) node.title = cell.title;
    }
    row.append(node);
  }
  return row;
}

function renderStages(report) {
  const target = el("perfStages");
  target.replaceChildren();
  if (!report.stages.length) {
    target.textContent = "No stage data.";
    return;
  }
  target.append(tableRow([
    { label: "Stage" }, { label: "avg" }, { label: "p50" }, { label: "p95" }, { label: "p99" }, { label: "max" }, { label: "over budget" },
  ], true));
  for (const stage of report.stages) {
    const tone = stage.overPercent > 20 ? "bad" : stage.overPercent > 5 ? "warn" : "good";
    target.append(tableRow([
      { value: stage.name },
      { value: round(stage.average) },
      { value: round(stage.p50) },
      { value: round(stage.p95) },
      { value: round(stage.p99) },
      { value: round(stage.max) },
      { value: `${round(stage.overPercent, 1)}%`, tone },
    ]));
  }
}

function renderWorst(report) {
  const target = el("perfWorst");
  target.replaceChildren();
  if (!report.worstFrames.length) {
    target.textContent = "No frames in window.";
    return;
  }
  target.append(tableRow([
    { label: "frame" }, { label: "total" }, { label: "recomp" }, { label: "layout" }, { label: "draw" }, { label: "present" }, { label: "nodes/batches" },
  ], true));
  for (const frame of report.worstFrames) {
    target.append(tableRow([
      { value: String(frame.frame) },
      { value: round(frame.totalMs), tone: frame.totalMs > FRAME_BUDGET_MS ? "bad" : "" },
      { value: frame.recompositionMs == null ? "—" : round(frame.recompositionMs) },
      { value: round(frame.layoutMs) },
      { value: round(frame.drawMs) },
      { value: round(frame.presentMs) },
      { value: `${frame.nodeCount}/${frame.batchCount}` },
    ]));
  }
}

function renderHot(report) {
  const target = el("perfHot");
  target.replaceChildren();
  if (!report.hotComponents.length) {
    target.textContent = "Enable Auto trace and interact with the app to collect CPU spans.";
    return;
  }
  target.append(tableRow([
    { label: "phase" }, { label: "component" }, { label: "count" }, { label: "total" }, { label: "avg" }, { label: "max" }, { label: "" },
  ], true));
  for (const component of report.hotComponents) {
    target.append(tableRow([
      { value: component.phase },
      { value: component.name, title: component.name },
      { value: String(component.count) },
      { value: `${component.totalMs} ms`, tone: component.totalMs > 16 ? "warn" : "" },
      { value: `${component.averageMs} ms` },
      { value: `${component.maxMs} ms` },
      { value: "" },
    ]));
  }
}

function renderMarkers(report) {
  const target = el("perfMarkers");
  target.replaceChildren();
  if (!perf.markers.length) {
    target.textContent = "No markers. Use Mark to tag a point for before/after comparisons.";
    return;
  }
  for (const marker of perf.markers) {
    const chip = document.createElement("span");
    chip.className = "markerChip";
    chip.textContent = `${marker.label} · ${new Date(marker.wall).toLocaleTimeString()}`;
    target.append(chip);
  }
}

function renderStatus(report) {
  const status = el("perfStatus");
  if (!report.frame.sampleCount) {
    status.textContent = "No timing data. Timing is collected automatically once connected.";
    return;
  }
  const range = report.frame.first != null ? `frames ${report.frame.first}–${report.frame.last}` : "";
  const trace = report.timeline.eventCount
    ? ` · ${report.timeline.recording ? "recording" : "captured"} ${report.timeline.eventCount} spans${report.timeline.dropped ? ` (${report.timeline.dropped} evicted)` : ""}`
    : "";
  const window = el("perfWindow").value === "all" ? "all" : `${el("perfWindow").value}s`;
  status.textContent = `Window ${window} · ${report.frame.sampleCount} samples · ${report.frame.spanSeconds}s · ${range}${trace} · ${perf.markers.length} markers`;
}

function render() {
  if (!isPerformanceTab()) return;
  const report = buildReport();
  renderStatus(report);
  renderSummary(report);
  renderHeatmap(report);
  renderStages(report);
  renderWorst(report);
  renderHot(report);
  renderMarkers(report);
  updateControls();
}

function refreshNow() { render(); }

function addMarker() {
  const input = el("markerLabel");
  const label = input.value.trim() || `Mark ${perf.markers.length + 1}`;
  perf.markers.push({ label, t: performance.now(), wall: Date.now() });
  if (perf.markers.length > 100) perf.markers.shift();
  input.value = "";
  render();
}

function clearCapture() {
  perf.frames = [];
  perf.markers = [];
  const observation = context.session.observation;
  if (observation?.recording && context.session.connection.connected) {
    // Restart the host capture so the timeline window is also reset.
    context.connection.send("timeline.unsubscribe");
    context.connection.send("timeline.subscribe");
  }
  if (observation) { observation.events = []; observation.dropped = 0; }
  render();
}

function isAutoTraceEnabled() { return perf.autoTrace; }

function setAutoTrace(enabled) {
  perf.autoTrace = enabled;
  writePref("guava.devtools.autoTrace", enabled);
  if (!context.session.connection.connected) return;
  if (!context.controls.hasCapability("timeline")) return;
  if (enabled && !context.session.observation.recording) context.connection.send("timeline.subscribe");
  else if (!enabled && context.session.observation.recording) context.connection.send("timeline.unsubscribe");
}

function updateControls() {
  const connected = context.session.connection.connected;
  const hasData = perf.frames.length > 0;
  el("addMarker").disabled = !connected;
  el("clearPerf").disabled = !hasData && !perf.markers.length;
  el("copyReport").disabled = !hasData;
  el("exportReportMD").disabled = !hasData;
  el("exportReportJSON").disabled = !hasData;
  el("perfAutoTrace").checked = perf.autoTrace;
}

function download(filename, content, mime) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function timestampName() {
  const date = new Date();
  const pad = value => String(value).padStart(2, "0");
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function stageTableMarkdown(report) {
  const lines = [
    "| Stage | avg (ms) | p50 | p95 | p99 | max | budget (ms) | over budget |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const stage of report.stages) {
    lines.push(`| ${stage.name} | ${round(stage.average)} | ${round(stage.p50)} | ${round(stage.p95)} | ${round(stage.p99)} | ${round(stage.max)} | ${stage.budget} | ${round(stage.overPercent, 1)}% |`);
  }
  return lines.join("\n");
}

function heatSeriesMarkdown(report) {
  const lines = ["Worst frame per bucket (ms), oldest → newest:", ""];
  for (const stage of report.heatmap.stages) {
    const series = report.heatmap.buckets
      .map(frame => frame ? round(frame[stage.key] ?? 0, 1) : "·")
      .join(" ");
    lines.push(`- ${stage.name} (budget ${stage.budget} ms): ${series}`);
  }
  return lines.join("\n");
}

function markdownReport(report) {
  const lines = [];
  lines.push("# GuavaUI Performance Report", "");
  const host = report.host?.appTitle ?? "unknown host";
  lines.push(`- Generated: ${report.generatedAt}`);
  lines.push(`- Host: ${host}`);
  lines.push(`- Window: ${report.window === "all" ? "all" : report.window + "s"} · samples: ${report.frame.sampleCount} · span: ${report.frame.spanSeconds}s`);
  if (report.frame.first != null) lines.push(`- Frames: ${report.frame.first}–${report.frame.last}`);
  lines.push("");
  lines.push("## Summary", "");
  lines.push(`- CPU throughput estimate: ${report.summary.cpuThroughputFPS ?? "—"} fps (reciprocal of CPU work, not measured display FPS)`);
  lines.push(`- Frame total: avg ${round(report.summary.totalAverageMs)} ms · p95 ${round(report.summary.totalP95Ms)} ms · p99 ${round(report.summary.totalP99Ms)} ms · max ${round(report.summary.totalMaxMs)} ms (60 fps budget ${round(FRAME_BUDGET_MS, 1)} ms)`);
  lines.push(`- Hitches over budget: ${report.summary.hitches} (${report.summary.hitchPercent}%) · severe (>33.3 ms): ${report.summary.severeHitches}`);
  lines.push(`- Presented frames: ${report.summary.presentedPercent == null ? "unknown" : report.summary.presentedPercent + "%"}`);
  lines.push(`- Average nodes: ${report.summary.averageNodeCount ?? "—"} · average batches: ${report.summary.averageBatchCount ?? "—"}`);
  lines.push("");
  lines.push("## Stage budgets", "", stageTableMarkdown(report), "");
  lines.push("## Heatmap", "", heatSeriesMarkdown(report), "");
  if (report.worstFrames.length) {
    lines.push("## Worst frames", "");
    lines.push("| frame | total | recomp | layout | draw | present | nodes | batches |");
    lines.push("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    for (const frame of report.worstFrames) {
      lines.push(`| ${frame.frame} | ${round(frame.totalMs)} | ${frame.recompositionMs == null ? "—" : round(frame.recompositionMs)} | ${round(frame.layoutMs)} | ${round(frame.drawMs)} | ${round(frame.presentMs)} | ${frame.nodeCount} | ${frame.batchCount} |`);
    }
    lines.push("");
  }
  if (report.hotComponents.length) {
    lines.push("## Hot components (CPU timeline)", "");
    lines.push(`Spans: ${report.timeline.eventCount} retained${report.timeline.dropped ? `, ${report.timeline.dropped} evicted at host` : ""}. Parent and child spans overlap; do not sum them.`, "");
    lines.push("| Phase | Component | Count | Total ms | Avg ms | Max ms |");
    lines.push("| --- | --- | ---: | ---: | ---: | ---: |");
    for (const component of report.hotComponents) {
      lines.push(`| ${component.phase} | ${component.name} | ${component.count} | ${component.totalMs} | ${component.averageMs} | ${component.maxMs} |`);
    }
    lines.push("");
  }
  if (report.markers.length) {
    lines.push("## Markers", "");
    for (const marker of report.markers) lines.push(`- ${marker.relativeSeconds}s · ${marker.label}`);
    lines.push("");
  }
  const concerning = report.recentLogs.filter(entry => context.format.logLevelRank(entry.level) >= context.format.logLevelRank("warning"));
  if (concerning.length) {
    lines.push("## Recent warning/error logs", "");
    for (const entry of concerning.slice(-60)) {
      const stamp = Number.isFinite(entry.timestamp) ? new Date(entry.timestamp * 1000).toISOString() : "";
      lines.push(`- ${stamp} ${(entry.level ?? "info").toUpperCase()} [${entry.label ?? "client"}] ${String(entry.message ?? "").replaceAll("\n", " ")}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

function jsonReport(report) {
  return JSON.stringify({
    schema: "guava-performance-report/1",
    generatedAt: report.generatedAt,
    host: report.host,
    window: report.window,
    frame: report.frame,
    summary: report.summary,
    stages: report.stages,
    heatmap: {
      stages: report.heatmap.stages,
      buckets: report.heatmap.buckets.map(frame => frame ? {
        frame: frame.frame,
        wall: frame.wall,
        totalMs: round(frame.totalMs, 3),
        recompositionMs: frame.recompositionMs == null ? null : round(frame.recompositionMs, 3),
        layoutMs: round(frame.layoutMs, 3),
        drawMs: round(frame.drawMs, 3),
        presentMs: round(frame.presentMs, 3),
        nodeCount: frame.nodeCount,
        batchCount: frame.batchCount,
      } : null),
    },
    worstFrames: report.worstFrames,
    hotComponents: report.hotComponents,
    markers: report.markers,
    timeline: report.timeline,
    recentLogs: report.recentLogs,
  }, null, 2);
}

function exportMarkdown() {
  const report = buildReport();
  download(`guava-performance-${timestampName()}.md`, markdownReport(report), "text/markdown");
}

function exportJSON() {
  const report = buildReport();
  download(`guava-performance-${timestampName()}.json`, jsonReport(report), "application/json");
}

function copyReport() {
  const markdown = markdownReport(buildReport());
  const status = el("perfStatus");
  const done = message => { status.textContent = message; };
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(markdown).then(() => done("Markdown report copied to clipboard."), () => fallbackCopy(markdown, done));
  } else {
    fallbackCopy(markdown, done);
  }
}

function fallbackCopy(text, done) {
  const area = document.createElement("textarea");
  area.value = text;
  document.body.append(area);
  area.select();
  try { document.execCommand("copy"); done("Markdown report copied to clipboard."); }
  catch { done("Copy failed; use Export MD instead."); }
  area.remove();
}

document.addEventListener("DOMContentLoaded", () => {
  el("perfAutoTrace").checked = perf.autoTrace;
  el("perfWindow").addEventListener("change", render);
  el("perfAutoTrace").addEventListener("change", event => setAutoTrace(event.target.checked));
  el("addMarker").addEventListener("click", addMarker);
  el("markerLabel").addEventListener("keydown", event => { if (event.key === "Enter") addMarker(); });
  el("clearPerf").addEventListener("click", clearCapture);
  el("copyReport").addEventListener("click", copyReport);
  el("exportReportMD").addEventListener("click", exportMarkdown);
  el("exportReportJSON").addEventListener("click", exportJSON);
  render();
  updateControls();
});

return {
  recordFrame, reset, setConnected, refreshNow, render,
  isAutoTraceEnabled, setAutoTrace,
  buildReport, markdownReport,
};
};
