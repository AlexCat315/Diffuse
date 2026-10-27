// @bun
// PluginSDK/src/index.ts
function capability(input, run, metadata = {}) {
  return { input, run, ...metadata };
}
function definePlugin(plugin) {
  return plugin;
}

// PluginSDK/src/steps.ts
var result = (value) => ({ result: value });
var failure = (error) => ({ error });
var run = (args, next, options = {}) => ({ run: args, ...next ? { next } : {}, ...options });
var whole = (next = "parse") => ({ emit: "", consumed: 0, next });
async function serve(request, stdout, context, handle) {
  const value = JSON.parse(request);
  if (value.process)
    return context.query("cove:process/host", value.process);
  if (typeof value.op !== "string")
    throw new Error("Missing operation");
  return handle(value, stdout);
}

// Editor/Plugins/SwiftSupport/src/index.ts
var lines = (text) => text.replace(/\x1b\[[0-9;]*m/g, "").split(/\r?\n/);
function problems(text) {
  const found = new Map;
  for (const line of lines(text)) {
    const match = /^(.*?):(\d+):(\d+):\s*(error|warning|note):\s*(.*)$/.exec(line);
    if (match)
      found.set(line, { file: match[1], line: Number(match[2]), column: Number(match[3]), severity: match[4], message: match[5] });
  }
  return [...found.values()];
}
function tests(text, known) {
  const values = new Map;
  const identify = (name) => {
    if (known.includes(name))
      return name;
    const candidates = known.filter((id) => [name, `${name}()`].some((value) => id.endsWith(`/${value}`) || id.endsWith(`.${value}`) || value.endsWith(`.${id}`)));
    return candidates.length === 1 ? candidates[0] : candidates.length ? undefined : name;
  };
  for (const line of lines(text)) {
    const xc = /Test Case '(?:-\[([^ ]+) ([^\]]+)\]|([^']+))' (passed|failed|skipped)/.exec(line);
    const st = /[\u2714\u2718\u279C] Test (?:"([^"]+)"|(\S+)) (passed|failed|skipped)/.exec(line);
    const name = xc ? xc[1] ? `${xc[1]}/${xc[2]}` : xc[3].replace(/\.([^.]+)$/, "/$1") : st?.[1] ?? st?.[2];
    if (name) {
      const id = identify(name);
      if (id)
        values.set(id, { id, status: xc?.[4] ?? st?.[3], message: null });
    }
  }
  return [...values.values()];
}
function describe(text) {
  const value = JSON.parse(text.slice(text.indexOf("{")));
  const products = (value.products ?? []).map((p) => ({ name: p.name, detail: Object.keys(p.type ?? {})[0] ?? "product" }));
  return { name: value.name, runnables: products.filter((p) => p.detail === "executable").map((p) => p.name), sections: [
    { title: "Products", items: products },
    { title: "Targets", items: (value.targets ?? []).map((t) => ({ name: t.name, detail: t.type ?? "" })) },
    { title: "Dependencies", items: (value.dependencies ?? []).map((d) => ({ name: d.identity, detail: d.url ?? d.path ?? "" })) }
  ] };
}
function task(request, stdout) {
  if (request.output) {
    if (!request.output.complete)
      return whole(request.next);
    if (request.next === "describe") {
      if (request.output.exit)
        return failure(request.output.stderr || stdout);
      try {
        return result(describe(stdout));
      } catch {
        return failure("SwiftPM printed no package description.");
      }
    }
    return result({ exit: request.output.exit, problems: problems(stdout), ...request.op === "test" ? { tests: tests(stdout, request.known ?? []) } : {} });
  }
  switch (request.op) {
    case "describe":
      return run(["package", "describe", "--type", "json"], "describe", { timeout: 300 });
    case "build":
      return run(["build"], "report", { stream: true });
    case "test":
      return run(["test", ...request.filter ? ["--filter", `(^|\\.)${request.filter.replace(/\(\)$/, "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\(\\))?$`] : []], "report", { stream: true });
    case "run":
      return request.target && !request.target.startsWith("-") ? run(["run", request.target], "report", { stream: true }) : failure("Name an executable product.");
    case "clean":
    case "resolve":
      return run(["package", request.op], "report", { stream: true });
    default:
      return failure(`Swift packages cannot ${request.op}.`);
  }
}
var src_default = definePlugin({ capabilities: {
  "language-server": capability({ record: { request: "string" } }, ({ request }, context) => context.query("cove:process/host", JSON.parse(request))),
  tasks: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, task)),
  view: capability({ record: { view: "string", state: "string", event: "string", context: "string" } }, ({ context }) => {
    try {
      const pins = JSON.parse(JSON.parse(context).text).pins;
      return { ui: { type: "scroll", child: { type: "column", spacing: 6, padding: 10, children: [
        { type: "text", text: `${pins.length} pinned packages`, style: "caption", tone: "muted" },
        { type: "table", columns: ["Package", "Version", "Revision", "Location"], rows: pins.map((pin) => ({ cells: [pin.identity ?? "?", pin.state?.version ?? (pin.state?.branch ? `branch ${pin.state.branch}` : "\u2014"), (pin.state?.revision ?? "").slice(0, 10), pin.location ?? ""] })) }
      ] } } };
    } catch {
      return { ui: { type: "text", text: "Invalid Package.resolved", tone: "danger" } };
    }
  })
} });
export {
  src_default as default,
  problems
};
