import { camel, componentValue } from './values.js';

self.onmessage = async ({ data }) => {
  let moduleURL;
  try {
    const { descriptor, assets, capabilityName, input, snapshot } = data;
    const imports = Object.create(null);
    for (const name of descriptor.witContract.imports) {
      const payload = snapshot?.values?.[name];
      if (!payload || typeof payload !== 'object' || !Number.isSafeInteger(snapshot?.sceneRevision) || snapshot.sceneRevision < 0) throw Error('Missing revision-bound query snapshot');
      const response = JSON.stringify(payload);
      if (new TextEncoder().encode(response).length > descriptor.execution.maximumOutputBytes) throw Error('Query snapshot is too large');
      imports[name] = Object.freeze({ query(request) {
        if (new TextEncoder().encode(request).length > 16384) throw Error('Query request is too large');
        const parsed = JSON.parse(request);
        if (parsed?.operation !== 'snapshot' || Object.keys(parsed).length !== 1) throw Error('Invalid query request');
        return response;
      } });
    }
    moduleURL = URL.createObjectURL(new Blob([assets['component.js']], { type: 'text/javascript' }));
    const { instantiate } = await import(moduleURL);
    const instance = await instantiate(async path => {
      if (!Object.hasOwn(assets, path) || !path.endsWith('.wasm')) throw Error('Undeclared core module');
      return WebAssembly.compile(assets[path]);
    }, Object.freeze(imports));
    const capability = descriptor.witContract.capabilityInputs.find(item => item.name === capabilityName);
    const iface = instance[descriptor.witContract.capabilitiesInterfaceName] ?? instance.capabilities;
    const result = iface[camel(capabilityName)](componentValue(input, capability.inputType));
    if (typeof result !== 'string' || new TextEncoder().encode(result).length > descriptor.execution.maximumOutputBytes) throw Error('Plugin result exceeds its limit');
    // Results are untrusted JSON. Native host primitives remain owned by the
    // application; this Worker never receives a scene mutator or registry.
    self.postMessage({ ok: true, value: JSON.parse(result) });
  } catch (error) { self.postMessage({ ok: false, error: String(error) }); }
  finally { if (moduleURL) URL.revokeObjectURL(moduleURL); self.close(); }
};
