import { capability, definePlugin, type JSONValue } from "@diffuse/plugin-sdk";
import { serve, run, result, failure, whole, type StepRequest, type Step } from "@diffuse/plugin-sdk/steps";
const lines = (text: string) => text.replace(/\x1b\[[0-9;]*m/g, "").split(/\r?\n/);
export function problems(text: string) {
  const found = new Map();
  for (const line of lines(text)) {
    const match = /^(.*?):(\d+):(\d+):\s*(error|warning|note):\s*(.*)$/.exec(line);
    if (match) found.set(line, { file: match[1], line: Number(match[2]), column: Number(match[3]), severity: match[4], message: match[5] });
  }
  return [...found.values()];
}
function tests(text: string, known: string[]) {
  const values = new Map<string, any>();
  const identify = (name: string) => {
    if (known.includes(name)) return name;
    const candidates = known.filter(id => [name, `${name}()`].some(value => id.endsWith(`/${value}`) || id.endsWith(`.${value}`) || value.endsWith(`.${id}`)));
    return candidates.length === 1 ? candidates[0] : candidates.length ? undefined : name;
  };
  for (const line of lines(text)) {
    const issue = /✘ Test (?:"([^"]+)"|(\S+)) recorded an issue at .*?:\d+:\d+:\s*(.*)$/.exec(line);
    if (issue) {
      const id = identify(issue[1] ?? issue[2]);
      if (id && !values.get(id)?.message) values.set(id, { id, status: "failed", message: issue[3] });
      continue;
    }
    const xc = /Test Case '(?:-\[([^ ]+) ([^\]]+)\]|([^']+))' (passed|failed|skipped)/.exec(line);
    const st = /[✔✘➜] Test (?:"([^"]+)"|(\S+)) (passed|failed|skipped)/.exec(line);
    const name = xc ? xc[1] ? `${xc[1]}/${xc[2]}` : xc[3].replace(/\.([^.]+)$/, "/$1") : st?.[1] ?? st?.[2];
    if (name) { const id = identify(name); if (id) values.set(id, { id, status: xc?.[4] ?? st?.[3], message: values.get(id)?.message ?? null }); }
  }
  return [...values.values()];
}
function describe(text: string) {
  const value = JSON.parse(text.slice(text.indexOf("{")));
  const products = (value.products ?? []).map((p: any) => ({ name: p.name, detail: Object.keys(p.type ?? {})[0] ?? "product" }));
  return { name: value.name, runnables: products.filter((p: any) => p.detail === "executable").map((p: any) => p.name), sections: [
    { title: "Products", items: products },
    { title: "Targets", items: (value.targets ?? []).map((t: any) => ({ name: t.name, detail: t.type ?? "" })) },
    { title: "Dependencies", items: (value.dependencies ?? []).map((d: any) => ({ name: d.identity, detail: d.url ?? d.path ?? "" })) }
  ] };
}
function task(request: StepRequest, stdout: string): Step {
  if (request.output) {
    if (!request.output.complete) return whole(request.next);
    if (request.next === "describe") {
      if (request.output.exit) return failure(request.output.stderr || stdout);
      try { return result(describe(stdout)); } catch { return failure("SwiftPM printed no package description."); }
    }
    return result({ exit: request.output.exit, problems: problems(stdout), ...(request.op === "test" ? { tests: tests(stdout, request.known ?? []) } : {}) });
  }
  switch (request.op) {
    case "describe": return run(["package", "describe", "--type", "json"], "describe", { timeout: 300 });
    case "build": return run(["build"], "report", { stream: true });
    case "test": return run(["test", ...(request.filter ? ["--filter", `(^|\\.)${request.filter.replace(/\(\)$/, "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\(\\))?$`] : [])], "report", { stream: true });
    case "run": return request.target && !request.target.startsWith("-") ? run(["run", request.target], "report", { stream: true }) : failure("Name an executable product.");
    case "clean": case "resolve": return run(["package", request.op], "report", { stream: true });
    default: return failure(`Swift packages cannot ${request.op}.`);
  }
}
export default definePlugin({ capabilities: {
  "language-server": capability({ record: { request: "string" } }, ({ request }, context) => context.query("cove:process/host", JSON.parse(request))),
  tasks: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, task)),
  view: capability({ record: { view: "string", state: "string", event: "string", context: "string" } }, ({ context }): JSONValue => {
    try {
      const pins = JSON.parse(JSON.parse(context).text).pins;
      return { ui: { type: "scroll", child: { type: "column", spacing: 6, padding: 10, children: [
        { type: "text", text: `${pins.length} pinned packages`, style: "caption", tone: "muted" },
        { type: "table", columns: ["Package", "Version", "Revision", "Location"], rows: pins.map((pin: any) => ({ cells: [pin.identity ?? "?", pin.state?.version ?? (pin.state?.branch ? `branch ${pin.state.branch}` : "—"), (pin.state?.revision ?? "").slice(0, 10), pin.location ?? ""] })) }
      ] } } };
    } catch { return { ui: { type: "text", text: "Invalid Package.resolved", tone: "danger" } }; }
  })
} });
