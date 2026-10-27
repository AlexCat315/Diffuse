/** Trusted Bun entry point, shipped beside the native broker. stdout is protocol-only. */
import { inspect } from "node:util";
import { pathToFileURL } from "node:url";
import type { Plugin, JSONValue } from "./index.ts";
import { validateInput, DisposalScope } from "./index.ts";

const write = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
for (const method of ["log", "info", "debug", "warn", "error"] as const) {
  console[method] = (...args: unknown[]) => process.stderr.write(args.map(value => typeof value === "string" ? value : inspect(value)).join(" ") + "\n");
}
let plugin: Plugin | undefined;
let pluginID = "";
let storageDirectory = "";
let sdkDirectory = "";
let scope = new DisposalScope();
let nextID = 0;
const pending = new Map<number, { resolve(value: JSONValue): void; reject(error: Error): void }>();
const active = new Map<string, AbortController>();
function query(permission: string, request: JSONValue): Promise<JSONValue> {
  const id = ++nextID;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject }); write({ type: "host", id, permission, request });
  });
}
async function receive(message: any): Promise<void> {
  if (message.type === "hostResult") {
    const waiter = pending.get(message.id); pending.delete(message.id);
    if (message.error) waiter?.reject(new Error(message.error)); else waiter?.resolve(message.value);
    return;
  }
  const id = String(message.id);
  try {
    if (message.method === "load") {
      pluginID = message.pluginID;
      storageDirectory = message.storageDirectory ?? "";
      sdkDirectory = message.sdkDirectory ?? "";
      plugin = (await import(pathToFileURL(message.entry).href)).default;
      if (!plugin?.capabilities) throw new Error("Invalid plugin exports");
      await plugin.activate?.(scope);
      write({ type: "result", id, value: Object.keys(plugin.capabilities).sort() });
    } else if (message.method === "cancel") {
      active.get(message.target)?.abort();
      write({ type: "result", id, value: null });
    } else if (message.method === "unload") {
      for (const controller of active.values()) controller.abort();
      for (const waiter of pending.values()) waiter.reject(new Error("Plugin disabled"));
      pending.clear();
      try { await plugin?.deactivate?.(); } finally { await scope.dispose(); plugin = undefined; }
      write({ type: "result", id, value: null });
    } else if (message.method === "invoke") {
      const capability = plugin?.capabilities[message.name];
      if (!capability) throw new Error("Unknown entry point");
      validateInput(message.input, capability.input);
      const controller = new AbortController(); active.set(id, controller);
      try {
        const value = await capability.run(message.input, { signal: controller.signal, pluginID, storageDirectory, sdkDirectory, query });
        if (controller.signal.aborted) throw new Error("Invocation cancelled");
        write({ type: "result", id, value });
      } finally { active.delete(id); }
    } else { throw new Error("Unknown runtime method"); }
  } catch (error) { write({ type: "result", id, error: error instanceof Error ? error.message : String(error) }); }
}
let buffer = "";
const decoder = new TextDecoder();
for await (const chunk of Bun.stdin.stream()) {
  buffer += decoder.decode(chunk, { stream: true });
  if (buffer.length > 384 * 1024 * 1024) throw new Error("Runtime frame exceeds limit");
  let index: number;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
    void receive(JSON.parse(line));
  }
}
for (const controller of active.values()) controller.abort();
try { await plugin?.deactivate?.(); } finally { await scope.dispose(); }
