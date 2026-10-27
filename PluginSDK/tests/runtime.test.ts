import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile, rm, mkdir, cp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DisposalScope, validateInput } from "../src/index.ts";
import { buildPlugin } from "../src/cli.ts";
import { parseStatus } from "../../Editor/Plugins/Git/src/index.ts";

test("scope cancels before releasing every registration, even when one cleanup fails", async () => {
  const scope = new DisposalScope(); const order: number[] = [];
  scope.own(() => { expect(scope.signal.aborted).toBe(true); order.push(1); });
  scope.own(() => { order.push(2); throw new Error("cleanup"); });
  await expect(scope.dispose()).rejects.toBeInstanceOf(AggregateError);
  await scope.dispose(); expect(order).toEqual([2, 1]);
  expect(() => scope.own(() => {})).toThrow();
});
test("input boundary rejects unknown fields and unsafe values", () => {
  const type = { record: { name: "string", values: { list: "integer" } } } as const;
  validateInput({ name: "中文", values: [1, 2] }, type);
  expect(() => validateInput({ name: "x", values: [NaN] }, type)).toThrow();
  expect(() => validateInput({ name: "x", values: [], extra: true }, type)).toThrow();
});
test("Git status preserves spaces, Unicode, renames and both index/worktree changes", () => {
  const status = parseStatus(["# branch.head main", "# branch.ab +2 -1", "1 MM N... 100644 100644 100644 abc def path with 空格", "2 R. N... 100644 100644 100644 abc def R100 renamed", "old name", "? new file", ""].join("\0"));
  expect(status.branch).toBe("main"); expect(status.ahead).toBe(2); expect(status.behind).toBe(1);
  expect(status.changes).toEqual([
    { path: "path with 空格", state: "modified", staged: true },
    { path: "path with 空格", state: "modified", staged: false },
    { path: "renamed", originalPath: "old name", state: "renamed", staged: true },
    { path: "new file", state: "untracked", staged: false }
  ]);
});
test("external plugin builds without the editor checkout and survives multiple runtime calls", async () => {
  const root = await mkdtemp(join(tmpdir(), "diffuse-sdk-"));
  try {
    const source = join(root, "source"); await mkdir(join(source, "src"), { recursive: true });
    await cp(resolve(import.meta.dir, ".."), join(root, "sdk"), { recursive: true, filter: path => !path.includes("node_modules") && !path.includes("tests") });
    await writeFile(join(source, "plugin.json"), JSON.stringify({ id: "external.counter", name: "Counter", version: 1, description: "External test", access: "read", imports: [], composable_host_capabilities: [] }));
    const marker = join(root, "executed.txt");
    await writeFile(join(source, "src/index.ts"), `import {writeFileSync} from 'node:fs'; import {definePlugin,capability} from '@diffuse/plugin-sdk'; writeFileSync(${JSON.stringify(marker)},'executed'); let n=0; export default definePlugin({capabilities:{increment:capability({record:{}},()=>++n)}});`);
    const output = join(root, "counter.coveplugin"); await buildPlugin(source, output);
    const metadata = await Bun.file(join(output, "capabilities.json")).json(); expect(metadata.entries[0].name).toBe("increment");
    expect(await Bun.file(marker).exists()).toBe(false);
    const process = Bun.spawn([Bun.which("bun") ?? Bun.argv[0], resolve(import.meta.dir, "../src/runner.ts")], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const reader = process.stdout.getReader(); let buffer = "";
    async function call(message: object) {
      process.stdin.write(JSON.stringify(message) + "\n"); process.stdin.flush();
      while (!buffer.includes("\n")) { const chunk = await reader.read(); if (chunk.done) throw new Error("Runtime closed"); buffer += new TextDecoder().decode(chunk.value); }
      const end = buffer.indexOf("\n"); const value = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1); return value;
    }
    try {
      expect((await call({ id: "1", method: "load", pluginID: "external.counter", entry: join(output, "plugin.js") })).value).toEqual(["increment"]);
      expect((await call({ id: "2", method: "invoke", name: "increment", input: {} })).value).toBe(1);
      expect((await call({ id: "3", method: "invoke", name: "increment", input: {} })).value).toBe(2);
      expect((await call({ id: "4", method: "invoke", name: "increment", input: { injected: true } })).error).toContain("unknown fields");
      await call({ id: "5", method: "unload" });
    } finally { process.kill(); await process.exited; }
  } finally { await rm(root, { recursive: true, force: true }); }
});
