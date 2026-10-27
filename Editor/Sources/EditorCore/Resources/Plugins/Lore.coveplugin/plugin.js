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
var complete = (request, stdout) => request.output?.exit === 0 ? result(null) : failure((request.output?.stderr || stdout || "Command failed").trim().slice(-2000));
var validBranch = (name) => !!name && !name.startsWith("-") && !name.startsWith("/") && !name.endsWith("/") && !name.endsWith(".") && !name.includes("..") && !name.includes("@{") && !/[\x00-\x20\x7f~^:?*\[\\]/.test(name) && name !== "@" && name.split("/").every((part) => !!part && !part.startsWith(".") && !part.endsWith(".lock"));
async function serve(request, stdout, context, handle) {
  const value = JSON.parse(request);
  if (value.process)
    return context.query("cove:process/host", value.process);
  if (typeof value.op !== "string")
    throw new Error("Missing operation");
  return handle(value, stdout);
}

// Editor/Plugins/Lore/src/index.ts
var lore = (args, next = "done", timeout = 120) => run(args, next, { env: { NO_COLOR: "1" }, timeout });
var events = (text) => text.split(`
`).flatMap((line) => {
  try {
    return [JSON.parse(line)];
  } catch {
    return [];
  }
});
function parseStatus(text) {
  const status = { changes: [], branch: null, upstream: null, ahead: 0, behind: 0 };
  for (const { tagName, data } of events(text)) {
    if (!data)
      continue;
    if (tagName === "repositoryStatusRevision") {
      status.branch = data.branchName || null;
      status.upstream = data.remoteBranchExist ? status.branch : null;
      status.ahead = data.isLocalAhead ? Math.max(1, (data.revisionLocalNumber ?? 0) - (data.revisionRemoteNumber ?? 0)) : 0;
      status.behind = data.isRemoteAhead ? Math.max(1, (data.revisionRemoteNumber ?? 0) - (data.revisionLocalNumber ?? 0)) : 0;
    } else if (tagName === "repositoryStatusFile" && data.path && data.type !== "directory") {
      status.changes.push({
        path: data.path,
        ...data.fromPath ? { originalPath: data.fromPath } : {},
        staged: !!data.flagStaged,
        state: data.flagConflict && data.flagConflictUnresolved ? "conflicted" : { add: "added", delete: "deleted", move: "renamed", copy: "copied" }[data.action] ?? "modified"
      });
    }
  }
  return status;
}
var locks = (text) => [...new Set(events(text).filter((e) => ["lockFileStatus", "lockFileQuery"].includes(e.tagName)).map((e) => e.data?.path).filter(Boolean))].sort();
function batch(request, stdout, args, values, after = result(null)) {
  if (request.output?.exit)
    return complete(request, stdout);
  let offset = Number(request.next) || 0;
  if (offset >= values.length)
    return after;
  const part = [];
  let bytes = 0;
  while (offset < values.length && part.length < 64 && (!part.length || bytes + Buffer.byteLength(values[offset]) < 6000)) {
    const value = values[offset++];
    bytes += Buffer.byteLength(value);
    part.push(value);
  }
  return lore([...args, ...part], String(offset));
}
function handle(request, stdout) {
  const { op, output, next } = request;
  if (output && !output.complete)
    return whole(next);
  switch (op) {
    case "status":
      return !output ? lore(["--json", "status", "--scan"], "parse") : output.exit ? complete(request, stdout) : result(parseStatus(stdout));
    case "history":
      return !output ? lore(["history", String(request.limit ?? 50), "--oneline"], "parse") : result(output.exit ? [] : stdout.split(`
`).flatMap((line) => {
        const match = /^(\d+) (.*)$/.exec(line);
        return match ? [{ id: match[1], summary: match[2] }] : [];
      }));
    case "branches": {
      if (!output)
        return lore(["--json", "branch", "list"], "parse");
      if (output.exit)
        return complete(request, stdout);
      const values = new Map;
      for (const e of events(stdout))
        if (e.tagName === "branchListEntry" && e.data?.name) {
          const previous = values.get(e.data.name);
          values.set(e.data.name, { name: e.data.name, current: !!e.data.isCurrent || !!previous?.current, remote: e.data.location === "remote" && previous?.remote !== false });
        }
      return result([...values.values()]);
    }
    case "locks":
      return !output ? lore(["--json", "lock", "status"], "parse") : result(output.exit ? [] : locks(stdout));
    case "context":
      if (!output)
        return lore(["--json", "status", "--scan"], "status");
      if (next === "status") {
        if (output.exit)
          return result("");
        const status = parseStatus(stdout);
        const summary = [`Branch: ${status.branch ?? "(none)"} (ahead ${status.ahead}, behind ${status.behind})`, ...status.changes.slice(0, 100).map((c) => `${c.path} (${c.state}${c.staged ? ", staged" : ""})`)].join(`
`);
        return lore(["--json", "lock", "status"], JSON.stringify({ summary }));
      }
      return result([JSON.parse(next ?? "{}").summary ?? "", ...output.exit ? [] : locks(stdout).map((path) => `Locked: ${path}`)].join(`
`));
    case "diff":
      return request.change?.path ? run(["diff", request.change.path], undefined, { env: { NO_COLOR: "1" } }) : failure("No change to compare.");
    case "stage":
    case "unstage":
      return batch(request, stdout, [op], request.paths ?? []);
    case "set-locked":
      return batch(request, stdout, ["lock", request.locked ? "acquire" : "release"], request.paths ?? []);
    case "discard": {
      if (next === "trashed")
        return result(null);
      const changes = request.changes ?? [];
      const created = changes.filter((c) => ["added", "untracked"].includes(c.state)).map((c) => c.path);
      return batch(request, stdout, ["reset"], changes.map((c) => c.path), created.length ? { trash: created, next: "trashed" } : result(null));
    }
    case "commit":
      if (output?.exit)
        return complete(request, stdout);
      if (!next && request.stageAll)
        return lore(["stage", "--scan", "."], "commit", 300);
      return !next || next === "commit" ? lore(["commit", request.message ?? ""], "done", 300) : result(null);
    case "switch-branch":
    case "create-branch":
      if (!validBranch(request.name ?? ""))
        return failure("Invalid branch name.");
      if (output?.exit)
        return complete(request, stdout);
      if (!next && op === "create-branch")
        return lore(["branch", "create", request.name], "switch");
      return !next || next === "switch" ? lore(["branch", "switch", request.name], "done", 600) : result(null);
    case "pull":
    case "push":
      return output ? complete(request, stdout) : lore([op === "pull" ? "sync" : "push"], "done", 600);
    case "init":
      return output ? complete(request, stdout) : /^lores?:\/\//.test(request.remote ?? "") ? lore(["repository", "create", request.remote]) : failure("Expected lore://host:port/name.");
    default:
      return failure(`Lore cannot ${op}.`);
  }
}
var src_default = definePlugin({ capabilities: {
  provider: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, handle))
} });
export {
  src_default as default,
  parseStatus
};
