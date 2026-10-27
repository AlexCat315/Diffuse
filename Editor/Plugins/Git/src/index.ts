import { capability, definePlugin } from "@diffuse/plugin-sdk";
import { serve, run, result, failure, complete, whole, validBranch, type StepRequest, type Step } from "@diffuse/plugin-sdk/steps";

const env = { GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0", GIT_EDITOR: "true", GIT_LITERAL_PATHSPECS: "1", GCM_INTERACTIVE: "never", NO_COLOR: "1" };
const git = (args: string[], next?: string, options: Step = {}) => run(args, next, { env, ...options });
const paths = (args: string[], values: string[], next = "done") => git([...args, "--pathspec-from-file=-", "--pathspec-file-nul"], next, { input: values.join("\0") });
const state = (code: string) => ({ M: "modified", T: "modified", A: "added", D: "deleted", R: "renamed", C: "copied", U: "conflicted" }[code]);
export function parseStatus(text: string) {
  const listing: any = { changes: [], branch: null, upstream: null, ahead: 0, behind: 0 };
  const records = text.split("\0");
  for (let index = 0; index < records.length; index++) {
    const record = records[index];
    if (record.startsWith("# branch.head ")) listing.branch = record.slice(14) === "(detached)" ? null : record.slice(14);
    else if (record.startsWith("# branch.upstream ")) listing.upstream = record.slice(18);
    else if (record.startsWith("# branch.ab ")) {
      const [ahead, behind] = record.slice(12).split(" "); listing.ahead = Number(ahead?.slice(1)) || 0; listing.behind = Number(behind?.slice(1)) || 0;
    } else if (record.startsWith("? ")) listing.changes.push({ path: record.slice(2), state: "untracked", staged: false });
    else if (["1", "2", "u"].includes(record[0])) {
      const count = record[0] === "1" ? 8 : record[0] === "2" ? 9 : 10;
      let start = 0; for (let field = 0; field < count; field++) start = record.indexOf(" ", start) + 1;
      const path = record.slice(start); const originalPath = record[0] === "2" ? records[++index] : undefined;
      if (record[0] === "u") listing.changes.push({ path, state: "conflicted", staged: false });
      else {
        if (state(record[2])) listing.changes.push({ path, originalPath, state: state(record[2]), staged: true });
        if (state(record[3])) listing.changes.push({ path, state: state(record[3]) === "renamed" ? "modified" : state(record[3]), staged: false });
      }
    }
  }
  return listing;
}
function handle(request: StepRequest, stdout: string): Step {
  const { op, next, output } = request;
  if (output && !output.complete) return whole(next);
  switch (op) {
    case "status": return !output ? git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], "parse")
      : output.exit === 0 ? result(parseStatus(stdout)) : complete(request, stdout);
    case "history":
      if (!output) return git(["log", "-n", String(Math.min(1000, Math.max(1, request.limit ?? 50))), "--no-color", "--pretty=format:%H%x1f%an%x1f%at%x1f%s%x1e"], "parse");
      return result(output.exit ? [] : stdout.split("\x1e").flatMap(record => {
        const [id, author, date, summary] = record.replace(/^\n/, "").split("\x1f");
        return id && summary !== undefined ? [{ id, author, date: Number(date), summary }] : [];
      }));
    case "branches":
      if (!output) return git(["for-each-ref", "--format=%(HEAD)%1f%(refname)", "refs/heads", "refs/remotes"], "parse");
      return output.exit ? complete(request, stdout) : result(stdout.split("\n").flatMap(line => {
        const [head, reference] = line.split("\x1f");
        if (reference?.startsWith("refs/heads/")) return [{ name: reference.slice(11), current: head === "*", remote: false }];
        if (reference?.startsWith("refs/remotes/") && !reference.endsWith("/HEAD")) return [{ name: reference.slice(13), current: false, remote: true }];
        return [];
      }));
    case "context":
      if (!output) return git(["status", "--porcelain=v1", "--branch", "--untracked-files=normal"], "parse");
      return result(output.exit ? "" : stdout.split("\n").filter(Boolean).slice(0, 101).join("\n"));
    case "diff": {
      const change = request.change;
      if (!change?.path) return failure("No change to compare.");
      if (change.state === "untracked") return git(["diff", "--no-color", "--no-index", "--", process.platform === "win32" ? "NUL" : "/dev/null", change.path]);
      return git(["diff", "--no-color", ...(change.staged ? ["--cached", "-M"] : []), "--", ...[change.originalPath, change.path].filter(Boolean)]);
    }
    case "stage": return output ? complete(request, stdout) : request.paths?.length ? paths(["add", "-A"], request.paths) : result(null);
    case "unstage":
      if (!next) return request.paths?.length ? git(["rev-parse", "--verify", "--quiet", "HEAD"], "unstage") : result(null);
      return next === "unstage" ? paths(output?.exit === 0 ? ["restore", "--staged"] : ["rm", "--cached", "-r", "-q"], request.paths) : complete(request, stdout);
    case "discard": {
      if (output?.exit) return complete(request, stdout);
      const changes = request.changes ?? []; const created = changes.filter((c: any) => ["untracked", "added"].includes(c.state));
      if (!next && created.some((c: any) => c.staged)) return paths(["rm", "--cached", "-r", "-q", "--force"], created.filter((c: any) => c.staged).map((c: any) => c.path), "trash");
      if ((!next || next === "trash") && created.length) return { trash: created.map((c: any) => c.path), next: "restore" };
      const tracked = changes.filter((c: any) => !created.includes(c));
      if ((!next || next === "trash" || next === "restore") && tracked.length) return paths(["restore", ...(tracked.some((c: any) => c.staged) ? ["--staged", "--worktree", "--source=HEAD"] : ["--worktree"])], [...new Set<string>(tracked.flatMap((c: any) => [c.originalPath, c.path].filter(Boolean)))].sort());
      return result(null);
    }
    case "commit":
      if (output?.exit) return complete(request, stdout);
      if (!next && request.stageAll) return git(["add", "-A"], "commit");
      return !next || next === "commit" ? git(["commit", "--quiet", "--file=-"], "done", { input: request.message ?? "" }) : result(null);
    case "push":
      if (!next) return git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"], "push");
      if (next === "push") {
        if (output?.exit) return complete(request, stdout);
        const status = parseStatus(stdout);
        return git(["push", "--quiet", ...(!status.upstream && status.branch ? ["--set-upstream", "origin", status.branch] : [])], "done", { timeout: 300 });
      }
      return complete(request, stdout);
    case "pull": return output ? complete(request, stdout) : git(["pull", "--ff-only", "--quiet"], "done", { timeout: 300 });
    case "switch-branch": case "create-branch":
      return output ? complete(request, stdout) : validBranch(request.name ?? "") ? git(["switch", "--quiet", ...(op === "create-branch" ? ["--create"] : []), request.name], "done") : failure("This is not a valid branch name.");
    case "init": return output ? complete(request, stdout) : git(["init", "--quiet"], "done");
    case "locks": return result([]);
    case "set-locked": return failure("Git does not lock files.");
    default: return failure(`Git cannot ${op}.`);
  }
}
export default definePlugin({ capabilities: {
  provider: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, handle))
} });
