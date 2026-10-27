import { capability, definePlugin } from "@diffuse/plugin-sdk";
import { serve, run, result, failure, complete, whole, validBranch, type StepRequest, type Step } from "@diffuse/plugin-sdk/steps";
const lore = (args: string[], next = "done", timeout = 120) => run(args, next, { env: { NO_COLOR: "1" }, timeout });
const events = (text: string) => text.split("\n").flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
export function parseStatus(text: string) {
  const status: any = { changes: [], branch: null, upstream: null, ahead: 0, behind: 0 };
  for (const { tagName, data } of events(text)) {
    if (!data) continue;
    if (tagName === "repositoryStatusRevision") {
      status.branch = data.branchName || null; status.upstream = data.remoteBranchExist ? status.branch : null;
      status.ahead = data.isLocalAhead ? Math.max(1, (data.revisionLocalNumber ?? 0) - (data.revisionRemoteNumber ?? 0)) : 0;
      status.behind = data.isRemoteAhead ? Math.max(1, (data.revisionRemoteNumber ?? 0) - (data.revisionLocalNumber ?? 0)) : 0;
    } else if (tagName === "repositoryStatusFile" && data.path && data.type !== "directory") {
      status.changes.push({ path: data.path, ...(data.fromPath ? { originalPath: data.fromPath } : {}), staged: !!data.flagStaged,
        state: data.flagConflict && data.flagConflictUnresolved ? "conflicted" : ({ add: "added", delete: "deleted", move: "renamed", copy: "copied" }[data.action as string] ?? "modified") });
    }
  }
  return status;
}
const locks = (text: string) => [...new Set(events(text).filter(e => ["lockFileStatus", "lockFileQuery"].includes(e.tagName)).map(e => e.data?.path).filter(Boolean))].sort();
function batch(request: StepRequest, stdout: string, args: string[], values: string[], after: Step = result(null)): Step {
  if (request.output?.exit) return complete(request, stdout);
  let offset = Number(request.next) || 0; if (offset >= values.length) return after;
  const part: string[] = []; let bytes = 0;
  while (offset < values.length && part.length < 64 && (!part.length || bytes + Buffer.byteLength(values[offset]) < 6000)) {
    const value = values[offset++]; bytes += Buffer.byteLength(value); part.push(value);
  }
  return lore([...args, ...part], String(offset));
}
function handle(request: StepRequest, stdout: string): Step {
  const { op, output, next } = request;
  if (output && !output.complete) return whole(next);
  switch (op) {
    case "status": return !output ? lore(["--json", "status", "--scan"], "parse") : output.exit ? complete(request, stdout) : result(parseStatus(stdout));
    case "history": return !output ? lore(["history", String(request.limit ?? 50), "--oneline"], "parse") : result(output.exit ? [] : stdout.split("\n").flatMap(line => {
      const match = /^(\d+) (.*)$/.exec(line); return match ? [{ id: match[1], summary: match[2] }] : [];
    }));
    case "branches": {
      if (!output) return lore(["--json", "branch", "list"], "parse");
      if (output.exit) return complete(request, stdout);
      const values = new Map(); for (const e of events(stdout)) if (e.tagName === "branchListEntry" && e.data?.name) {
        const previous = values.get(e.data.name);
        values.set(e.data.name, { name: e.data.name, current: !!e.data.isCurrent || !!previous?.current, remote: e.data.location === "remote" && previous?.remote !== false });
      }
      return result([...values.values()]);
    }
    case "locks": return !output ? lore(["--json", "lock", "status"], "parse") : result(output.exit ? [] : locks(stdout));
    case "context":
      if (!output) return lore(["--json", "status", "--scan"], "status");
      if (next === "status") {
        if (output.exit) return result("");
        const status = parseStatus(stdout);
        const summary = [`Branch: ${status.branch ?? "(none)"} (ahead ${status.ahead}, behind ${status.behind})`, ...status.changes.slice(0, 100).map((c: any) => `${c.path} (${c.state}${c.staged ? ", staged" : ""})`) ].join("\n");
        return lore(["--json", "lock", "status"], JSON.stringify({ summary }));
      }
      return result([JSON.parse(next ?? "{}").summary ?? "", ...(output.exit ? [] : locks(stdout).map(path => `Locked: ${path}`))].join("\n"));
    case "diff": return request.change?.path ? run(["diff", request.change.path], undefined, { env: { NO_COLOR: "1" } }) : failure("No change to compare.");
    case "stage": case "unstage": return batch(request, stdout, [op], request.paths ?? []);
    case "set-locked": return batch(request, stdout, ["lock", request.locked ? "acquire" : "release"], request.paths ?? []);
    case "discard": {
      if (next === "trashed") return result(null);
      const changes = request.changes ?? []; const created = changes.filter((c: any) => ["added", "untracked"].includes(c.state)).map((c: any) => c.path);
      return batch(request, stdout, ["reset"], changes.map((c: any) => c.path), created.length ? { trash: created, next: "trashed" } : result(null));
    }
    case "commit":
      if (output?.exit) return complete(request, stdout);
      if (!next && request.stageAll) return lore(["stage", "--scan", "."], "commit", 300);
      return !next || next === "commit" ? lore(["commit", request.message ?? ""], "done", 300) : result(null);
    case "switch-branch": case "create-branch":
      if (!validBranch(request.name ?? "")) return failure("Invalid branch name.");
      if (output?.exit) return complete(request, stdout);
      if (!next && op === "create-branch") return lore(["branch", "create", request.name], "switch");
      return !next || next === "switch" ? lore(["branch", "switch", request.name], "done", 600) : result(null);
    case "pull": case "push": return output ? complete(request, stdout) : lore([op === "pull" ? "sync" : "push"], "done", 600);
    case "init": return output ? complete(request, stdout) : /^lores?:\/\//.test(request.remote ?? "") ? lore(["repository", "create", request.remote]) : failure("Expected lore://host:port/name.");
    default: return failure(`Lore cannot ${op}.`);
  }
}
export default definePlugin({ capabilities: {
  provider: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, handle))
} });
