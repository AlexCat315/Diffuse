import { mkdir, lstat, writeFile, readFile } from "node:fs/promises";
import { join } from "node:path";
import { hostJob, type InvocationContext } from "@diffuse/plugin-sdk";
import type { ModelTool } from "./models.ts";
const tool = (name: string, description: string, properties: any, required: string[]): ModelTool => ({ type: "function",
  function: { name, description, parameters: { type: "object", properties, required, additionalProperties: false } } });
const string = { type: "string" };
export const authoringTools = [
  tool("diffuse_plugin_guide", "Read the installed public TypeScript plugin SDK contract before creating a plugin.", {}, []),
  tool("diffuse_plugin_write", "Create or update one source file of a new plugin in the assistant's development directory. Read the SDK guide first.", { id: string, path: string, content: string }, ["id", "path", "content"]),
  tool("diffuse_plugin_build", "Build the plugin without executing it. Returns a .coveplugin package path for user review.", { id: string }, ["id"]),
  tool("diffuse_plugin_review", "Show the built plugin's installation review. The user chooses whether to enable its code.", { package: string }, ["package"])
];
export async function authoring(name: string, input: any, context: InvocationContext, signal: AbortSignal): Promise<any> {
  signal.throwIfAborted();
  if (!context.sdkDirectory) throw new Error("The installed SDK is missing; run cove studio plugins prepare");
  if (name === "diffuse_plugin_guide") return { guide: await readFile(join(context.sdkDirectory, "README.md"), "utf8"),
    contract: await readFile(join(context.sdkDirectory, "index.ts"), "utf8") };
  const development = join(context.storageDirectory, "development");
  const packages = join(context.storageDirectory, "packages");
  if (name === "diffuse_plugin_review") {
    if (typeof input.package !== "string" || !input.package.startsWith(packages + "/") || !input.package.endsWith(".coveplugin") || input.package.includes("..")) throw new Error("Invalid built package");
    return hostJob(context, "diffuse:editor/host", { operation: "review", package: input.package }, signal);
  }
  if (typeof input.id !== "string" || !/^[a-z][a-z0-9.-]{2,63}$/.test(input.id)) throw new Error("Invalid plugin id");
  const source = join(development, input.id);
  if (name === "diffuse_plugin_write") {
    if (typeof input.path !== "string" || !/^(plugin\.json|src\/[a-zA-Z0-9_./-]+\.ts|resources\/[a-zA-Z0-9_./-]+)$/.test(input.path)
      || input.path.split("/").some((value: string) => !value || value === "." || value === "..")
      || typeof input.content !== "string" || Buffer.byteLength(input.content) > 1024 * 1024) throw new Error("Invalid source file");
    const segments = input.path.split("/"); let directory = source;
    for (const segment of ["", ...segments.slice(0, -1)]) {
      directory = join(directory, segment); await mkdir(directory, { recursive: true });
      if ((await lstat(directory)).isSymbolicLink()) throw new Error("Source symlinks are forbidden");
    }
    const file = join(source, input.path);
    try { if ((await lstat(file)).isSymbolicLink()) throw new Error("Source symlinks are forbidden"); }
    catch (error: any) { if (error.code !== "ENOENT") throw error; }
    await writeFile(file, input.content, { mode: 0o600 }); return { path: file };
  }
  if (name !== "diffuse_plugin_build") throw new Error("Unknown authoring tool");
  await mkdir(packages, { recursive: true });
  const output = join(packages, `${input.id}-${crypto.randomUUID()}.coveplugin`);
  const process = Bun.spawn([globalThis.process.execPath, "--no-macros", join(context.sdkDirectory, "cli.js"), "build", source, output], { stdout: "pipe", stderr: "pipe" });
  const abort = () => process.kill(); signal.addEventListener("abort", abort, { once: true });
  const timeout = setTimeout(abort, 30_000);
  try {
    const [code, diagnostics] = await Promise.all([process.exited, new Response(process.stderr).text()]);
    signal.throwIfAborted(); if (code !== 0) throw new Error(diagnostics.slice(0, 8000) || "Plugin build failed");
    return { package: output };
  } finally { clearTimeout(timeout); signal.removeEventListener("abort", abort); }
}
