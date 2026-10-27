import { expect, test } from "bun:test";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { InvocationContext, JSONValue } from "../src/index.ts";
import { authoring } from "../../Editor/Plugins/AI/src/authoring.ts";

test("the installed SDK lets AI build a third-party plugin outside the source checkout and present review", async () => {
  const storageDirectory = await mkdtemp(join(tmpdir(), "diffuse-authoring-"));
  const calls: any[] = [];
  const host: InvocationContext = { pluginID: "studio.ai", storageDirectory,
    sdkDirectory: resolve(import.meta.dir, "../../Engine/Sources/PluginRuntime/Resources/plugin-sdk"), signal: new AbortController().signal,
    async query(_, value: any): Promise<JSONValue> { calls.push(value); return value.operation === "review" ? { job: "review" } : { status: "completed", value: { review: "presented" } }; } };
  try {
    expect((await authoring("diffuse_plugin_guide", {}, host, host.signal)).guide).toContain("TypeScript");
    await authoring("diffuse_plugin_write", { id: "example.external", path: "plugin.json", content: JSON.stringify({ id: "example.external", name: "External", version: 1, description: "External", access: "read", imports: [], composable_host_capabilities: [], contributes: {} }) }, host, host.signal);
    await authoring("diffuse_plugin_write", { id: "example.external", path: "src/index.ts", content: "import {capability,definePlugin} from '@diffuse/plugin-sdk';export default definePlugin({capabilities:{inspect:capability({record:{}},()=>({ok:true}))}});" }, host, host.signal);
    const output = await authoring("diffuse_plugin_build", { id: "example.external" }, host, host.signal);
    expect(JSON.parse(await readFile(join(output.package, "plugin.json"), "utf8")).runtime.engine).toBe("bun");
    expect(JSON.parse(await readFile(join(output.package, "capabilities.json"), "utf8")).entries[0].name).toBe("inspect");
    await authoring("diffuse_plugin_review", output, host, host.signal);
    expect(calls[0].operation).toBe("review");
    await expect(authoring("diffuse_plugin_write", { id: "example.external", path: "src/../../escape.ts", content: "" }, host, host.signal)).rejects.toThrow();
  } finally { await rm(storageDirectory, { recursive: true, force: true }); }
});
