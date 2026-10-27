import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const repository = resolve(import.meta.dir, "../..");
const executable = process.env.DIFFUSE_TEST_HOST ?? resolve(repository, "Editor/.build/mac/debug/EditorApp.app/Contents/Helpers/DiffusePluginHost");
test.skipIf(!existsSync(executable))("native broker validates the Bun package without executing it", async () => {
  const host = Bun.spawn([executable], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const reader = host.stdout.getReader(); let buffer = Buffer.alloc(0);
  async function write(value: unknown) {
    const bytes = Buffer.from(JSON.stringify(value)), header = Buffer.alloc(4); header.writeUInt32BE(bytes.length);
    host.stdin.write(Buffer.concat([header, bytes])); host.stdin.flush();
  }
  async function read() {
    while (buffer.length < 4 || buffer.length < buffer.readUInt32BE(0) + 4) {
      const part = await reader.read(); if (part.done) throw new Error("Host closed: " + await new Response(host.stderr).text());
      buffer = Buffer.concat([buffer, Buffer.from(part.value)]);
    }
    const length = buffer.readUInt32BE(0), value = JSON.parse(buffer.subarray(4, length + 4).toString()); buffer = buffer.subarray(length + 4); return value;
  }
  async function call(method: string, extra: object = {}) {
    const id = crypto.randomUUID().toUpperCase(); await write({ id, method, ...extra });
    while (true) {
      const reply = await read(); expect(reply.id).toBe(id);
      if (reply.hostCall) {
        await write({ id, method: "host_result", input: Buffer.from("[]").toString("base64") }); continue;
      }
      expect(reply.error).toBeUndefined(); expect(reply.ok).toBe(true);
      return reply.payload ? JSON.parse(Buffer.from(reply.payload, "base64").toString()) : undefined;
    }
  }
  try {
    expect((await call("handshake")).runtime).toBe("bun");
    const pluginPath = resolve(repository, "Editor/Sources/EditorCore/Resources/Plugins/AI.coveplugin");
    const inspection = await call("validate_package", { pluginPath });
    // The exact Swift authorization digest is tested by Engine tests; obtain an approved record through a fixture supplied by that gate.
    expect(inspection.manifest.runtime.engine).toBe("bun");
    expect(inspection.contracts.find((value: any) => value.id === "studio.ai.view").id).toBe("studio.ai.view");
  } finally { host.kill(); await host.exited; }
}, 15_000);
