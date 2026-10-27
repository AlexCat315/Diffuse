import { mkdir, rm, cp } from "node:fs/promises";
import { resolve, join } from "node:path";
const directory = resolve(import.meta.dir, "../../Engine/Sources/PluginRuntime/Resources/plugin-sdk");
await rm(directory, { recursive: true, force: true }); await mkdir(directory, { recursive: true });
for (const name of ["index.ts", "steps.ts", "services.ts"]) await cp(join(import.meta.dir, name), join(directory, name));
await cp(resolve(import.meta.dir, "../README.md"), join(directory, "README.md"));
for (const name of ["cli", "bundler"]) {
  const built = await Bun.build({ entrypoints: [join(import.meta.dir, `${name}.ts`)], target: "bun", format: "esm", minify: true });
  if (!built.success || built.outputs.length !== 1) throw new AggregateError(built.logs, "SDK build failed");
  await Bun.write(join(directory, `${name}.js`), built.outputs[0]);
}
