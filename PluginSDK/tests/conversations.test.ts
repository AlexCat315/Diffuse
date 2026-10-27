import { expect, test } from "bun:test";
import { mkdtemp, rm, readdir } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Conversations, type Generate } from "../../Editor/Plugins/AI/src/conversations.ts";
import { events } from "../../Editor/Plugins/AI/src/models.ts";

test("project and standalone conversations run independently; switching and creating preserve their messages", async () => {
  const directory = await mkdtemp(join(tmpdir(), "diffuse-conversations-"));
  const store = new Conversations(directory);
  const releases = new Map<string, () => void>();
  const generate = (id: string): Generate => async (_, signal, delta) => {
    delta(id + "开始");
    await new Promise<void>(resolve => { releases.set(id, resolve); signal.addEventListener("abort", () => resolve(), { once: true }); });
    if (!signal.aborted) delta(id + "完成");
  };
  try {
    const a = await store.create("/project-a"), b = await store.create("/project-a"), c = await store.create();
    await store.start(a.id, "A", generate("A")); await store.start(b.id, "B", generate("B")); await store.start(c.id, "C", generate("C"));
    expect(store.active.size).toBe(3);
    await store.create("/project-b");
    await store.cancel(a.id); expect(store.active.size).toBe(2);
    expect((await store.get(a.id))?.status).toBe("cancelled");
    releases.get("B")?.(); releases.get("C")?.();
    await Promise.all([...store.active.values()].map(value => value.task));
    expect((await store.get(b.id))?.messages[1].text).toBe("B开始B完成");
    expect((await store.get(c.id))?.project).toBeUndefined();
    const restored = new Conversations(directory);
    expect((await restored.list()).length).toBe(4);
    expect((await restored.get(a.id))?.messages[0].text).toBe("A");
    expect((await readdir(directory)).filter(file => file.endsWith(".lock"))).toEqual([]);
  } finally { await store.dispose(); await rm(directory, { recursive: true, force: true }); }
});
test("two project hosts cannot write the same running conversation; disable cancels and persists", async () => {
  const directory = await mkdtemp(join(tmpdir(), "diffuse-owner-"));
  const first = new Conversations(directory), second = new Conversations(directory);
  try {
    const conversation = await first.create();
    const wait: Generate = async (_, signal) => new Promise<void>(resolve => signal.addEventListener("abort", () => resolve(), { once: true }));
    await first.start(conversation.id, "one", wait);
    await expect(second.start(conversation.id, "two", wait)).rejects.toThrow("另一个项目");
    await second.cancel(conversation.id);
    await Promise.all([...first.active.values()].map(value => value.task));
    await first.dispose();
    expect((await second.get(conversation.id))?.status).toBe("cancelled");
    await expect(first.create()).rejects.toThrow("disabled");
  } finally { await first.dispose(); await second.dispose(); await rm(directory, { recursive: true, force: true }); }
});
test("SSE handles fragmented UTF-8, multiple data lines and stream completion", async () => {
  const encoded = new TextEncoder().encode('data: {"choices":[{"delta":{"content":"你好"}}]}\r\n\r\ndata: [DONE]\n\n');
  const chunks = new ReadableStream<Uint8Array>({ start(controller) {
    for (let index = 0; index < encoded.length; index++) controller.enqueue(encoded.slice(index, index + 1));
    controller.close();
  } });
  const values = []; for await (const value of events(chunks)) values.push(value);
  expect(values).toEqual([{ choices: [{ delta: { content: "你好" } }] }]);
});
