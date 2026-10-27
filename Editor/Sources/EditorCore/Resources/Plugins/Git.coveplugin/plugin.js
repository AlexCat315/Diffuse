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

// Editor/Plugins/Git/src/index.ts
var env = { GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0", GIT_EDITOR: "true", GIT_LITERAL_PATHSPECS: "1", GCM_INTERACTIVE: "never", NO_COLOR: "1" };
var git = (args, next, options = {}) => run(args, next, { env, ...options });
var paths = (args, values, next = "done") => git([...args, "--pathspec-from-file=-", "--pathspec-file-nul"], next, { input: values.join("\x00") });
var state = (code) => ({ M: "modified", T: "modified", A: "added", D: "deleted", R: "renamed", C: "copied", U: "conflicted" })[code];
function parseStatus(text) {
  const listing = { changes: [], branch: null, upstream: null, ahead: 0, behind: 0 };
  const records = text.split("\x00");
  for (let index = 0;index < records.length; index++) {
    const record = records[index];
    if (record.startsWith("# branch.head "))
      listing.branch = record.slice(14) === "(detached)" ? null : record.slice(14);
    else if (record.startsWith("# branch.upstream "))
      listing.upstream = record.slice(18);
    else if (record.startsWith("# branch.ab ")) {
      const [ahead, behind] = record.slice(12).split(" ");
      listing.ahead = Number(ahead?.slice(1)) || 0;
      listing.behind = Number(behind?.slice(1)) || 0;
    } else if (record.startsWith("? "))
      listing.changes.push({ path: record.slice(2), state: "untracked", staged: false });
    else if (["1", "2", "u"].includes(record[0])) {
      const count = record[0] === "1" ? 8 : record[0] === "2" ? 9 : 10;
      let start = 0;
      for (let field = 0;field < count; field++)
        start = record.indexOf(" ", start) + 1;
      const path = record.slice(start);
      const originalPath = record[0] === "2" ? records[++index] : undefined;
      if (record[0] === "u")
        listing.changes.push({ path, state: "conflicted", staged: false });
      else {
        if (state(record[2]))
          listing.changes.push({ path, originalPath, state: state(record[2]), staged: true });
        if (state(record[3]))
          listing.changes.push({ path, state: state(record[3]) === "renamed" ? "modified" : state(record[3]), staged: false });
      }
    }
  }
  return listing;
}
function handle(request, stdout) {
  const { op, next, output } = request;
  if (output && !output.complete)
    return whole(next);
  switch (op) {
    case "status":
      return !output ? git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], "parse") : output.exit === 0 ? result(parseStatus(stdout)) : complete(request, stdout);
    case "history":
      if (!output)
        return git(["log", "-n", String(Math.min(1000, Math.max(1, request.limit ?? 50))), "--no-color", "--pretty=format:%H%x1f%an%x1f%at%x1f%s%x1e"], "parse");
      return result(output.exit ? [] : stdout.split("\x1E").flatMap((record) => {
        const [id, author, date, summary] = record.replace(/^\n/, "").split("\x1F");
        return id && summary !== undefined ? [{ id, author, date: Number(date), summary }] : [];
      }));
    case "branches":
      if (!output)
        return git(["for-each-ref", "--format=%(HEAD)%1f%(refname)", "refs/heads", "refs/remotes"], "parse");
      return output.exit ? complete(request, stdout) : result(stdout.split(`
`).flatMap((line) => {
        const [head, reference] = line.split("\x1F");
        if (reference?.startsWith("refs/heads/"))
          return [{ name: reference.slice(11), current: head === "*", remote: false }];
        if (reference?.startsWith("refs/remotes/") && !reference.endsWith("/HEAD"))
          return [{ name: reference.slice(13), current: false, remote: true }];
        return [];
      }));
    case "context":
      if (!output)
        return git(["status", "--porcelain=v1", "--branch", "--untracked-files=normal"], "parse");
      return result(output.exit ? "" : stdout.split(`
`).filter(Boolean).slice(0, 101).join(`
`));
    case "diff": {
      const change = request.change;
      if (!change?.path)
        return failure("No change to compare.");
      if (change.state === "untracked")
        return git(["diff", "--no-color", "--no-index", "--", process.platform === "win32" ? "NUL" : "/dev/null", change.path]);
      return git(["diff", "--no-color", ...change.staged ? ["--cached", "-M"] : [], "--", ...[change.originalPath, change.path].filter(Boolean)]);
    }
    case "stage":
      return output ? complete(request, stdout) : request.paths?.length ? paths(["add", "-A"], request.paths) : result(null);
    case "unstage":
      if (!next)
        return request.paths?.length ? git(["rev-parse", "--verify", "--quiet", "HEAD"], "unstage") : result(null);
      return next === "unstage" ? paths(output?.exit === 0 ? ["restore", "--staged"] : ["rm", "--cached", "-r", "-q"], request.paths) : complete(request, stdout);
    case "discard": {
      if (output?.exit)
        return complete(request, stdout);
      const changes = request.changes ?? [];
      const created = changes.filter((c) => ["untracked", "added"].includes(c.state));
      if (!next && created.some((c) => c.staged))
        return paths(["rm", "--cached", "-r", "-q", "--force"], created.filter((c) => c.staged).map((c) => c.path), "trash");
      if ((!next || next === "trash") && created.length)
        return { trash: created.map((c) => c.path), next: "restore" };
      const tracked = changes.filter((c) => !created.includes(c));
      if ((!next || next === "trash" || next === "restore") && tracked.length)
        return paths(["restore", ...tracked.some((c) => c.staged) ? ["--staged", "--worktree", "--source=HEAD"] : ["--worktree"]], [...new Set(tracked.flatMap((c) => [c.originalPath, c.path].filter(Boolean)))].sort());
      return result(null);
    }
    case "commit":
      if (output?.exit)
        return complete(request, stdout);
      if (!next && request.stageAll)
        return git(["add", "-A"], "commit");
      return !next || next === "commit" ? git(["commit", "--quiet", "--file=-"], "done", { input: request.message ?? "" }) : result(null);
    case "push":
      if (!next)
        return git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"], "push");
      if (next === "push") {
        if (output?.exit)
          return complete(request, stdout);
        const status = parseStatus(stdout);
        return git(["push", "--quiet", ...!status.upstream && status.branch ? ["--set-upstream", "origin", status.branch] : []], "done", { timeout: 300 });
      }
      return complete(request, stdout);
    case "pull":
      return output ? complete(request, stdout) : git(["pull", "--ff-only", "--quiet"], "done", { timeout: 300 });
    case "switch-branch":
    case "create-branch":
      return output ? complete(request, stdout) : validBranch(request.name ?? "") ? git(["switch", "--quiet", ...op === "create-branch" ? ["--create"] : [], request.name], "done") : failure("This is not a valid branch name.");
    case "init":
      return output ? complete(request, stdout) : git(["init", "--quiet"], "done");
    case "locks":
      return result([]);
    case "set-locked":
      return failure("Git does not lock files.");
    default:
      return failure(`Git cannot ${op}.`);
  }
}
var src_default = definePlugin({ capabilities: {
  provider: capability({ record: { request: "string", stdout: "string" } }, (input, context) => serve(input.request, input.stdout, context, handle))
} });
export {
  src_default as default,
  parseStatus
};
