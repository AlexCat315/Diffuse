'use strict';
/**
 * Compile the Electron main process JS to V8 bytecode via bytenode.
 *
 * Must be executed with the same Electron binary that will run the packaged app:
 *   ./node_modules/.bin/electron scripts/compile-bytecode.cjs
 *
 * This ensures the bytecode is compatible with Electron's exact V8 version.
 * Running with plain `node` would produce incompatible bytecode and crash at startup.
 */

const bytenode = require('bytenode');
const fs = require('fs');
const path = require('path');

const distMain = path.resolve(__dirname, '../dist/main');
const indexJs = path.join(distMain, 'index.js');
const indexJsc = path.join(distMain, 'index.jsc');

if (!fs.existsSync(indexJs)) {
  console.error('[bytenode] ERROR: dist/main/index.js not found.');
  console.error('[bytenode] Run `npm run build` before this step.');
  process.exit(1);
}

// Compile main process entry to V8 bytecode using Electron's V8 engine
bytenode.compileFile(indexJs, indexJsc);
console.log('[bytenode] dist/main/index.js → dist/main/index.jsc');

// Replace the original JS with a tiny loader.
// The loader is intentionally plain JS (not compiled) — it only bootstraps bytenode
// and has zero business logic, so its readability is harmless.
const loader = [
  "'use strict';",
  "// Bootstraps the compiled main process. Actual logic is in index.jsc (V8 bytecode).",
  "require('bytenode');",
  "require('./index.jsc');",
  "",
].join('\n');

fs.writeFileSync(indexJs, loader, 'utf8');
console.log('[bytenode] dist/main/index.js replaced with bytecode loader.');

process.exit(0);
