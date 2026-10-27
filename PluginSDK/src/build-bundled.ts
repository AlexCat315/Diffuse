import { readdir, rm, rename } from "node:fs/promises";
import { resolve, join } from "node:path";
import { buildPlugin } from "./cli.ts";
const repository = resolve(import.meta.dir, "../..");
const source = join(repository, "Editor/Plugins");
const output = join(repository, "Editor/Sources/EditorCore/Resources/Plugins");
const sources = (await readdir(source)).filter(name => name !== "Themes").map(name => [join(source, name), name]);
sources.push([join(source, "Themes/Default"), "Default"]);
for (const [directory, name] of sources) {
  const destination = join(output, `${name}.coveplugin`);
  const staging = join(output, `${name}-${crypto.randomUUID()}.coveplugin`);
  await buildPlugin(directory, staging);
  await rm(destination, { recursive: true, force: true });
  await rename(staging, destination);
  console.log(`Built ${name}`);
}
