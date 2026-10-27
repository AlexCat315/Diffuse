import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import ai from "../../Editor/Plugins/AI/src/index.ts";
import { Conversations } from "../../Editor/Plugins/AI/src/conversations.ts";

test("long Unicode answers fit the public UI text boundary without gaps", async () => {
  const storage = await mkdtemp(join(tmpdir(), "diffuse-ai-view-"));
  const store = new Conversations(join(storage, "conversations"));
  try {
    const thread = await store.create();
    const answer = "你好世界".repeat(2_000);
    thread.messages.push({ id: crypto.randomUUID(), role: "assistant", text: answer, state: "completed" });
    await store.save(thread);
    const result: any = await ai.capabilities.view.run({ view: "assistant", state: JSON.stringify({ selected: thread.id }), event: "",
      context: JSON.stringify({ storage, workspace: "", projects: [] }) }, {
      pluginID: "studio.ai", storageDirectory: storage, sdkDirectory: "", signal: new AbortController().signal,
      query: async () => []
    });
    const texts: string[] = [];
    function visit(node: any) {
      if (node.type === "text") { expect(Buffer.byteLength(node.text)).toBeLessThanOrEqual(4096); texts.push(node.text); }
      for (const child of node.children ?? []) visit(child);
      if (node.child) visit(node.child);
    }
    visit(result.ui);
    expect(texts.filter(value => value.includes("你好")).join("")).toBe(answer);
  } finally { await ai.deactivate(); await store.dispose(); await rm(storage, { recursive: true, force: true }); }
});

test("a provider plugin can own its credentials without requiring an AI-plugin API key", async () => {
  const storage = await mkdtemp(join(tmpdir(), "diffuse-ai-provider-"));
  try {
    const result: any = await ai.capabilities.view.run({ view: "assistant", state: "", context: JSON.stringify({ storage, projects: [] }),
      event: JSON.stringify({ action: "configure", values: { format: "service:example.models/v1", model: "example", key: "" } }) }, {
      pluginID: "studio.ai", storageDirectory: storage, sdkDirectory: "", signal: new AbortController().signal,
      query: async () => [{ pluginID: "example.provider", id: "example", data: { service: "example.models/v1" } }]
    });
    expect(result.state.error).toBeUndefined();
    expect(result.state.settings).toBe(false);
    expect((await Bun.file(join(storage, "model.json")).json()).format).toBe("service:example.models/v1");
  } finally { await ai.deactivate(); await rm(storage, { recursive: true, force: true }); }
});

test("navigation, conversation and context regions share selection through the public conversation service", async () => {
  const storage = await mkdtemp(join(tmpdir(), "diffuse-ai-regions-"));
  const host = { pluginID: "studio.ai", storageDirectory: storage, sdkDirectory: "", signal: new AbortController().signal, query: async () => [] };
  const context = JSON.stringify({ storage, workspace: "/project-a", projects: [{ directory: "/project-a", name: "Project A" }] });
  try {
    const navigation: any = await ai.capabilities.view.run({ view: "ai-conversations", state: "", context,
      event: JSON.stringify({ action: "new", arguments: { project: "/project-a" } }) }, host);
    const main: any = await ai.capabilities.view.run({ view: "assistant", state: "", context, event: "" }, host);
    const details: any = await ai.capabilities.view.run({ view: "ai-context", state: "", context, event: "" }, host);
    const current: any = await ai.capabilities.conversation.run({ request: JSON.stringify({ operation: "current" }) }, host);
    expect(navigation.state.selected).toBe(main.state.selected);
    expect(details.state.selected).toBe(main.state.selected);
    expect(current.id).toBe(main.state.selected);
    expect(current.project).toBe("/project-a");
    expect(current).not.toHaveProperty("apiKey");
  } finally { await ai.deactivate(); await rm(storage, { recursive: true, force: true }); }
});
