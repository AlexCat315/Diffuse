// @bun
// PluginSDK/src/runner.ts
import { inspect } from "util";
import { pathToFileURL } from "url";
// PluginSDK/src/index.ts
class DisposalScope {
  #disposed = false;
  #cleanups = [];
  controller = new AbortController;
  get signal() {
    return this.controller.signal;
  }
  own(dispose) {
    if (this.#disposed)
      throw new Error("Plugin scope is disposed");
    this.#cleanups.push(dispose);
  }
  async dispose() {
    if (this.#disposed)
      return;
    this.#disposed = true;
    this.controller.abort();
    const failures = [];
    for (const cleanup of this.#cleanups.reverse()) {
      try {
        await cleanup();
      } catch (error) {
        failures.push(error);
      }
    }
    this.#cleanups = [];
    if (failures.length)
      throw new AggregateError(failures, "Plugin cleanup failed");
  }
}
function validateInput(value, type, path = "$") {
  if (typeof type === "string") {
    const valid = type === "bool" ? typeof value === "boolean" : type === "string" ? typeof value === "string" : typeof value === "number" && Number.isFinite(value) && (type !== "integer" || Number.isSafeInteger(value) && value >= -2147483648 && value <= 2147483647);
    if (!valid)
      throw new Error(`${path} must be ${type}`);
  } else if ("optional" in type) {
    if (value !== undefined && value !== null)
      validateInput(value, type.optional, path);
  } else if ("enum" in type) {
    if (typeof value !== "string" || !type.enum.includes(value))
      throw new Error(`${path} is not an allowed value`);
  } else if ("oneOf" in type) {
    let matches = 0;
    for (const child of type.oneOf) {
      try {
        validateInput(value, child, path);
        matches++;
      } catch {}
    }
    if (matches !== 1)
      throw new Error(`${path} must match exactly one alternative`);
  } else if ("list" in type) {
    if (!Array.isArray(value))
      throw new Error(`${path} must be an array`);
    value.forEach((item, index) => validateInput(item, type.list, `${path}[${index}]`));
  } else {
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error(`${path} must be an object`);
    const record = value;
    if (Object.keys(record).some((key) => !(key in type.record)))
      throw new Error(`${path} has unknown fields`);
    for (const [key, child] of Object.entries(type.record))
      validateInput(record[key], child, `${path}.${key}`);
  }
}

// PluginSDK/src/runner.ts
var write = (value) => process.stdout.write(JSON.stringify(value) + `
`);
for (const method of ["log", "info", "debug", "warn", "error"]) {
  console[method] = (...args) => process.stderr.write(args.map((value) => typeof value === "string" ? value : inspect(value)).join(" ") + `
`);
}
var plugin;
var pluginID = "";
var storageDirectory = "";
var sdkDirectory = "";
var scope = new DisposalScope;
var nextID = 0;
var pending = new Map;
var active = new Map;
function query(permission, request) {
  const id = ++nextID;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    write({ type: "host", id, permission, request });
  });
}
async function receive(message) {
  if (message.type === "hostResult") {
    const waiter = pending.get(message.id);
    pending.delete(message.id);
    if (message.error)
      waiter?.reject(new Error(message.error));
    else
      waiter?.resolve(message.value);
    return;
  }
  const id = String(message.id);
  try {
    if (message.method === "load") {
      pluginID = message.pluginID;
      storageDirectory = message.storageDirectory ?? "";
      sdkDirectory = message.sdkDirectory ?? "";
      plugin = (await import(pathToFileURL(message.entry).href)).default;
      if (!plugin?.capabilities)
        throw new Error("Invalid plugin exports");
      await plugin.activate?.(scope);
      write({ type: "result", id, value: Object.keys(plugin.capabilities).sort() });
    } else if (message.method === "cancel") {
      active.get(message.target)?.abort();
      write({ type: "result", id, value: null });
    } else if (message.method === "unload") {
      for (const controller of active.values())
        controller.abort();
      for (const waiter of pending.values())
        waiter.reject(new Error("Plugin disabled"));
      pending.clear();
      try {
        await plugin?.deactivate?.();
      } finally {
        await scope.dispose();
        plugin = undefined;
      }
      write({ type: "result", id, value: null });
    } else if (message.method === "invoke") {
      const capability = plugin?.capabilities[message.name];
      if (!capability)
        throw new Error("Unknown entry point");
      validateInput(message.input, capability.input);
      const controller = new AbortController;
      active.set(id, controller);
      try {
        const value = await capability.run(message.input, { signal: controller.signal, pluginID, storageDirectory, sdkDirectory, query });
        if (controller.signal.aborted)
          throw new Error("Invocation cancelled");
        write({ type: "result", id, value });
      } finally {
        active.delete(id);
      }
    } else {
      throw new Error("Unknown runtime method");
    }
  } catch (error) {
    write({ type: "result", id, error: error instanceof Error ? error.message : String(error) });
  }
}
var buffer = "";
var decoder = new TextDecoder;
for await (const chunk of Bun.stdin.stream()) {
  buffer += decoder.decode(chunk, { stream: true });
  if (buffer.length > 402653184)
    throw new Error("Runtime frame exceeds limit");
  let index;
  while ((index = buffer.indexOf(`
`)) >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    receive(JSON.parse(line));
  }
}
for (const controller of active.values())
  controller.abort();
try {
  await plugin?.deactivate?.();
} finally {
  await scope.dispose();
}
