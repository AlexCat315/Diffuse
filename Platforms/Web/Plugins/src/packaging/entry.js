#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, readdir, rm, rename, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { boundResources } from './resources.js';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export async function packageWebPlugin(input, output, host) {
  input = resolve(input); output = resolve(output); host = resolve(host);
  await mkdir(dirname(output), { recursive: true });
  const temporary = await mkdtemp(join(dirname(output), '.guava-plugin-'));
  try {
    const source = join(temporary, 'source.guavaplugin'); const destination = join(temporary, 'output');
    await mkdir(source); await mkdir(destination);
    const names = await readdir(input);
    if (names.length !== 3 || names.some(name => !['plugin.json', 'component.wasm', 'capabilities.wit'].includes(name))) {
      throw Error('Expected a three-file .guavaplugin package');
    }
    for (const name of names) await cp(join(input, name), join(source, name), { dereference: false });
    const descriptor = JSON.parse(execFileSync(host, ['--export-web', source], { maxBuffer: 4 * 1024 * 1024, encoding: 'utf8', timeout: 30000 }));
    for (const [name, expected] of [['component.wasm', descriptor.inspection.componentHash], ['capabilities.wit', descriptor.inspection.witHash]]) {
      if (digest(await readFile(join(source, name))) !== expected) throw Error('Plugin changed during packaging');
    }
    // Resolve from the package root, independent of the caller's working directory.
    const cli = fileURLToPath(new URL('../../node_modules/@bytecodealliance/jco/dist/jco.js', import.meta.url));
    execFileSync(process.execPath, [cli, 'transpile', join(source, 'component.wasm'), '-o', destination,
      '--name', 'component', '--instantiation', 'async', '--no-nodejs-compat', '--no-wasi-shim', '--base64-cutoff', '0'], { stdio: ['ignore', 'pipe', 'inherit'], timeout: 30000 });
    const files = [];
    let coreModuleCount = 0;
    for (const name of (await readdir(destination)).sort()) {
      if (!name.endsWith('.js') && !name.endsWith('.wasm')) continue;
      const path = join(destination, name);
      let bytes = await readFile(path);
      if (name.endsWith('.wasm')) {
        if (++coreModuleCount > 64) throw Error('Too many core modules');
        bytes = boundResources(bytes); await writeFile(path, bytes);
      }
      files.push({ path: name, sha256: digest(bytes) });
    }
    if (files.filter(file => file.path.endsWith('.js')).length !== 1) throw Error('Expected one self-contained Jco instantiation module');
    descriptor.files = files;
    // Browser engines expose no instruction-fuel counter. The dedicated Worker
    // is terminated on a wall-clock deadline; memory limits are encoded above.
    descriptor.execution = { mode: 'web-worker', maximumMemoryBytes: 67108864, timeoutMilliseconds: 5000, maximumOutputBytes: 1048576 };
    const metadata = JSON.stringify(descriptor) + '\n';
    await writeFile(join(destination, 'plugin.web.json'), metadata);
    await writeFile(join(destination, 'plugin.web.integrity'), digest(Buffer.from(metadata)) + '\n');
    // Never replace an existing publication accidentally.
    await rename(destination, output);
    return join(output, 'plugin.web.json');
  } finally { await rm(temporary, { recursive: true, force: true }); }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [input, output, host, ...extra] = process.argv.slice(2);
  if (!host || extra.length) throw Error('Usage: guava-plugin-web <plugin.guavaplugin> <new-output-directory> <GuavaPluginHost>');
  console.log(await packageWebPlugin(input, output, host));
}
