#!/usr/bin/env bun
import { mkdir, readdir, readFile, writeFile, cp, rm, lstat, realpath } from "node:fs/promises";
import { resolve, join, relative, isAbsolute } from "node:path";
import { metadata } from "./metadata.ts";

export async function buildPlugin(source: string, output: string): Promise<void> {
  const root = await realpath(source);
  const destination = resolve(output);
  const manifest = JSON.parse(await readFile(join(root, "plugin.json"), "utf8"));
  if (!/^[a-z][a-z0-9.-]{2,63}$/.test(manifest.id)) throw new Error("Invalid plugin id");
  if (!destination.endsWith(".coveplugin")) throw new Error("Output must end in .coveplugin");
  const inside = relative(root, destination);
  if (!inside || (!inside.startsWith("..") && !isAbsolute(inside))) throw new Error("Output must be outside the source directory");
  try { await lstat(destination); throw new Error("Output already exists"); }
  catch (error: any) { if (error.code !== "ENOENT") throw error; }
  const entry = join(root, "src/index.ts");
  const executable = await Bun.file(entry).exists();
  const staging = `${destination}.building-${crypto.randomUUID()}`;
  await mkdir(staging, { recursive: true });
  try {
    if (executable) {
      const contract = metadata(await readFile(entry, "utf8"), entry);
      // Disable Bun macros in a dedicated build process, including macros from dependencies.
      // Compiling an uninstalled package must not execute its source.
      const build = Bun.spawn([process.execPath, "--no-macros", (await Bun.file(join(import.meta.dir, "bundler.js")).exists() ? join(import.meta.dir, "bundler.js") : join(import.meta.dir, "bundler.ts")), entry, join(staging, "plugin.js")],
        { stdout: "pipe", stderr: "pipe" });
      const [code, diagnostics] = await Promise.all([build.exited, new Response(build.stderr).text()]);
      if (code !== 0) throw new Error("Plugin build failed: " + diagnostics);
      await writeFile(join(staging, "capabilities.json"), JSON.stringify(contract, null, 2));
      manifest.runtime = { engine: "bun", entry: "plugin.js", compatibility: 1 };
    } else if (manifest.runtime) { throw new Error("Runtime plugin is missing src/index.ts"); }
    for (const resource of manifest.resources ?? []) {
      if (!/^resources\//.test(resource.path) || resource.path.split("/").some((p: string) => !p || p === "." || p === "..") || /[\\:\0]/.test(resource.path)) throw new Error("Invalid resource path");
      let current = root;
      for (const segment of resource.path.split("/")) {
        current = join(current, segment);
        if ((await lstat(current)).isSymbolicLink()) throw new Error("Resource symlinks are forbidden");
      }
      const target = join(staging, resource.path);
      await mkdir(resolve(target, ".."), { recursive: true });
      await cp(current, target);
    }
    await writeFile(join(staging, "plugin.json"), JSON.stringify(manifest, null, 2) + "\n");
    const { rename } = await import("node:fs/promises");
    await rename(staging, destination);
  } finally { await rm(staging, { recursive: true, force: true }); }
}

if (import.meta.main) {
  const [command, source, output] = Bun.argv.slice(2);
  if (command !== "build" || !source || !output) {
    console.error("Usage: diffuse-plugin build SOURCE OUTPUT.coveplugin"); process.exit(2);
  }
  await buildPlugin(source, output);
}
