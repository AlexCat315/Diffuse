# Diffuse Plugin SDK

Diffuse desktop plugins are written in TypeScript and executed by the Bun version pinned in `runtime.json`. The native editor, its renderer and platform services remain Swift/Cove. A plugin does not import EditorCore or require a Diffuse checkout.

## Build a plugin

Create `plugin.json` and `src/index.ts` in your own directory. With the SDK installed, run:

```sh
bunx --bun --package @diffuse/plugin-sdk diffuse-plugin build ./my-plugin ./my-plugin.coveplugin
```

Until the SDK is published, distribute the tarball from `bun pm pack` in this directory and install it using `bun add ./diffuse-plugin-sdk-0.1.0.tgz`. Repository contributors can run `./cove plugin build SOURCE --output OUTPUT.coveplugin`.

```json
{
  "id": "example.counter", "version": 1, "name": "Counter",
  "description": "A persistent counter panel", "access": "read",
  "imports": [], "composable_host_capabilities": [],
  "contributes": {
    "cove.ui.panel/v1": [{
      "id": "counter", "title": "Counter", "surface": "counter", "entryPoint": "view"
    }]
  }
}
```

```ts
import { capability, definePlugin } from '@diffuse/plugin-sdk';
let count = 0;
export default definePlugin({ capabilities: {
  view: capability({ record: {
    view: 'string', state: 'string', event: 'string', context: 'string'
  } }, ({ event }) => {
    if (event && JSON.parse(event).action === 'increment') count++;
    return { ui: { type: 'column', spacing: 8, children: [
      { type: 'text', text: String(count) },
      { type: 'button', title: 'Increment', action: 'increment' }
    ] } };
  })
} });
```

The build bundles code and SDK imports into `plugin.js`, emits static `capabilities.json`, and adds the Bun runtime declaration to `plugin.json`. Inspection validates metadata and hashes without importing executable code. Declarative extensions only need their manifest and declared resources. Install the resulting folder through Diffuse's plugin settings.

## Lifecycle and authority

`activate(scope)` runs once per live plugin instance. Register cleanup with `scope.own(...)`; `scope.signal` is aborted on unload. `deactivate()` can flush state. The host gives cleanup a bounded interval, then terminates the plugin process. A new instance never reuses the old instance's registrations or handles.

Bun plugins are trusted desktop extensions with the operating system authority of their process. Manifest declarations govern Diffuse's brokered services; they do not sandbox `node:fs`, `Bun.spawn` or direct network access. Process separation provides a fault boundary. Do not describe this model as a Wasm permission sandbox.

## Views

Use `cove.ui.panel/v1` with an `entryPoint`. Add `surface` to provide a top-level mode. All packages use the same component renderer. `state` and `event` are JSON strings; the first event is empty. `context` supplies current content, workspace, window project catalog and the plugin's application storage directory. Return `{ state?, ui, effects?, refreshAfterMilliseconds? }`. Omitted state retains the previous value. Refresh intervals are bounded to 100–10,000 ms. Control values live in `event.values`; secret fields are never placed in diagnostic snapshots.

A mode owns its central view. Other panels mount into it with `inSurface: 'owner.plugin.mode'` and `slot: 'leading' | 'trailing' | 'bottom'`. A panel cannot declare both `surface` and `inSurface`. Side regions have separate collapse controls; multiple contributions appear as tabs. These panels do not appear in the workbench. Declare a plugin dependency on the mode owner when your panel requires it.

For example, an AI artifact plugin can contribute `{ id: 'example-artifacts', title: 'Artifacts', entryPoint: 'view', inSurface: 'studio.ai.assistant', slot: 'trailing' }`. The AI plugin's `diffuse.ai.conversation/v1` service accepts `{ operation: 'current' }` and returns the current conversation or null: ID, title, project, status, skills and up to 20 recent messages, each bounded to the last 16,000 characters. Credentials are excluded. Use the public service rather than reading another plugin's storage.

## Services and extension points

A service is declared under `cove.service/v1` with `{ id, title, entryPoint }`. Its entry accepts `{ request: 'string' }` and returns JSON. IDs include a version, for example `example.translation/v1`.

To call another plugin, declare `cove:service/host` in `imports` and use:

```ts
import { hostJob } from '@diffuse/plugin-sdk';
const result = await hostJob(context, 'cove:service/host', {
  service: 'example.translation/v1', input: { text: 'Hello' }
});
```

The job belongs to the caller and is cancelled when it exits. Service providers must honor cancellation and release their own long-running stream handles. Keep individual service calls short; start long work and return a handle, then expose poll/cancel operations.

Declare an extension point with `cove.extensionPoint/v1: [{ id, title }]`. Other packages contribute `cove.extension/v1: [{ id, point, data }]` and declare a dependency on the package owning the point. The owner reads extensions through `context.query('cove:service/host', { operation: 'extensions', point })`. The owner validates its domain-specific data. Unknown or disabled points expose no extensions.

The AI package owns `studio.ai.providers/v1`, `studio.ai.tools/v1` and `studio.ai.skills/v1`; these are plugin contracts, not native provider-format switches.

## Verification

```sh
./cove studio plugins prepare
./cove studio plugins verify
./cove build Editor --mac
./cove test Engine --filter BunRuntimeTests
```

## Installed development tools

`context.storageDirectory` is application storage owned by the current plugin. `context.sdkDirectory` contains a bundled `cli.js`, SDK source and this guide. Run the installed CLI with the current Bun executable and `--no-macros`; it can build a separate source directory without the Diffuse checkout. The SDK also ships as an ordinary package tarball; it has not been published to npm yet.

Node layout attributes include `width`, `fillWidth`, `maxWidth`, `minHeight`, `background` (`canvas`, `surface`, `raised`) and `cornerRadius`. `fillWidth:true` fills the available width, bounded by `maxWidth` when supplied. A `textField` can set `multiline:true`. Panels must provide `entryPoint`; the former host-owned `view` selector is rejected.

AI's built-in development tools read this contract, write bounded TypeScript/resource files into their own development directory, build a package and request the generic installation review. Third-party tool and provider plugins use the same service contract. A build or review never automatically enables a package.

An approved installation copies the reviewed package into application storage and records its exact authorization and enabled state. It is available across loaded projects and restored on restart; altered code, contracts, permissions or resources require another review. Disabling retains the package and data; uninstalling removes the installation. Project authorization files alone never enable code.
