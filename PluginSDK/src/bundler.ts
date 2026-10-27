import { resolve } from "node:path";
const [entry, output] = Bun.argv.slice(2);
const result = await Bun.build({ entrypoints: [entry!], target: "bun", format: "esm", minify: false,
  plugins: [{ name: "diffuse-sdk", setup(build) {
    build.onResolve({ filter: /^@diffuse\/plugin-sdk(?:\/steps)?$/ }, ({ path }) => ({
      path: resolve(import.meta.dir, path.endsWith("/steps") ? "steps.ts" : "index.ts")
    }));
  } }] });
if (!result.success || result.outputs.length !== 1) {
  console.error(result.logs); process.exit(1);
}
await Bun.write(output!, result.outputs[0]);
