import { digest, fetchBytes } from './integrity.js';
import { componentValue } from './values.js';
import { validateComposition } from './composition.js';

const creationToken = Symbol();
const decoder = new TextDecoder('utf-8', { fatal: true });
async function descriptorAt(url, integrity) {
  url = new URL(url, location.href);
  if (url.origin !== location.origin) throw Error('Plugin bundles must have the application origin');
  const bytes = await fetchBytes(url, 4 * 1024 * 1024);
  // Integrity comes from the application's trusted build catalog. A plugin
  // cannot authenticate its own generated JavaScript by supplying a digest.
  if (!/^[a-f0-9]{64}$/.test(integrity ?? '') || await digest(bytes) !== integrity) throw Error('Plugin bundle is not in the trusted application catalog');
  const descriptor = JSON.parse(decoder.decode(bytes));
  if (descriptor.formatVersion !== 1 || descriptor.execution?.mode !== 'web-worker' || descriptor.execution.timeoutMilliseconds > 5000 || descriptor.execution.maximumOutputBytes > 1048576) throw Error('Invalid plugin bundle');
  return { url, descriptor, authorization: await digest(bytes) };
}

/** One approved bundle. Each prepare call runs in a fresh, disposable Worker. */
export class WebPluginSession {
  #descriptor; #assets;
  static async inspect(url, integrity) {
    const { descriptor, authorization } = await descriptorAt(url, integrity);
    return structuredClone({ inspection: descriptor.inspection, authorization });
  }
  static async open(url, { integrity, authorization }) {
    const bundle = await descriptorAt(url, integrity);
    if (bundle.authorization !== authorization) throw Error('Plugin changed; authorization is required');
    const assets = Object.create(null);
    for (const file of bundle.descriptor.files) {
      if (!/^component(?:\.core\d*)?\.(?:js|wasm)$/.test(file.path) || file.path in assets) throw Error('Invalid plugin asset path');
      const bytes = await fetchBytes(new URL(file.path, bundle.url));
      if (await digest(bytes) !== file.sha256) throw Error('Plugin asset integrity mismatch');
      assets[file.path] = file.path.endsWith('.js') ? decoder.decode(bytes) : bytes;
    }
    if (!assets['component.js']) throw Error('Missing component bindings');
    return new WebPluginSession(bundle.descriptor, assets, creationToken);
  }
  constructor(descriptor, assets, token) {
    if (token !== creationToken) throw Error('Use WebPluginSession.open');
    this.#descriptor = descriptor; this.#assets = assets;
  }
  async prepare(capabilityID, input, { snapshot, signal, timeoutMilliseconds = 5000 } = {}) {
    const descriptor = this.#descriptor;
    const capability = descriptor.witContract.capabilityInputs.find(item => `${descriptor.inspection.manifest.id}.${item.name}` === capabilityID);
    if (!capability) throw Error('Unknown plugin capability');
    if (new TextEncoder().encode(JSON.stringify(input)).length > 1048576) throw Error('Input is too large');
    componentValue(input, capability.inputType);
    if (!Number.isFinite(timeoutMilliseconds) || timeoutMilliseconds <= 0) throw Error('Invalid timeout');
    if (signal?.aborted) throw signal.reason;
    let grantedSnapshot;
    if (descriptor.witContract.imports.length) {
      if (!Number.isSafeInteger(snapshot?.sceneRevision) || snapshot.sceneRevision < 0) throw Error('Missing snapshot revision');
      const values = Object.create(null); let size = 0;
      for (const name of descriptor.witContract.imports) {
        const payload = snapshot.values?.[name];
        if (!payload || typeof payload !== 'object') throw Error('Missing query snapshot');
        size += new TextEncoder().encode(JSON.stringify(payload)).length;
        if (size > 512 * 1024) throw Error('Query snapshots exceed 512 KiB');
        values[name] = payload;
      }
      grantedSnapshot = { sceneRevision: snapshot.sceneRevision, values };
    }
    const result = await new Promise((resolve, reject) => {
      const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
      const complete = (error, value) => { clearTimeout(timer); signal?.removeEventListener('abort', abort); worker.terminate(); error ? reject(error) : resolve(value); };
      const abort = () => complete(signal.reason ?? Error('Plugin cancelled'));
      const timer = setTimeout(() => complete(Error('Plugin deadline exceeded')), Math.min(timeoutMilliseconds, descriptor.execution.timeoutMilliseconds));
      worker.onmessage = ({ data }) => data.ok ? complete(null, data.value) : complete(Error(data.error));
      worker.onerror = event => complete(Error(event.message || 'Plugin Worker failed'));
      signal?.addEventListener('abort', abort, { once: true });
      try { worker.postMessage({ descriptor, assets: this.#assets, capabilityName: capability.name, input, snapshot: grantedSnapshot }); }
      catch (error) { complete(error); }
    });
    if (descriptor.inspection.manifest.access === 'read') return { kind: 'read', value: result };
    return { kind: 'hostCalls', calls: validateComposition(result, descriptor) };
  }
}
