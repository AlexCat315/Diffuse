import { capability, definePlugin, type JSONValue } from "@diffuse/plugin-sdk";
import { mkdir, readFile, writeFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { Conversations, type Conversation, type ModelConfig } from "./conversations.ts";
import { generate } from "./models.ts";
import { extensions, skillInstructions, tools, generateByService } from "./extensions.ts";

import { completion, disposeCompletions } from "./completions.ts";

const stores = new Map<string, Conversations>();
const text = (value: string, style = "body", tone = "normal"): any => ({ type: "text", text: value || " ", style, tone });
const column = (children: any[], options: any = {}): any => ({ type: "column", spacing: 8, children, ...options });
const row = (children: any[], options: any = {}): any => ({ type: "row", spacing: 8, children, ...options });
const button = (title: string, action: string, args: any = {}, style = "ghost"): any => ({ type: "button", title, action, arguments: args, style });
const field = (id: string, placeholder: string, value?: string, secure = false): any => ({ type: "textField", id, placeholder, ...(value === undefined ? {} : { value }), secure });
const defaults: ModelConfig = { format: "openai-compatible", baseURL: "https://api.deepseek.com/", model: "deepseek-chat", apiKey: "" };
async function configAt(directory: string): Promise<ModelConfig> {
  try { return { ...defaults, ...JSON.parse(await readFile(join(directory, "model.json"), "utf8")) }; } catch { return defaults; }
}
async function saveConfig(directory: string, config: ModelConfig) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const destination = join(directory, "model.json"), temporary = `${destination}.${crypto.randomUUID()}.tmp`;
  try { await writeFile(temporary, JSON.stringify(config), { mode: 0o600 }); await rename(temporary, destination); }
  finally { await rm(temporary, { force: true }); }
}
function threadRow(thread: Conversation, selected?: string) {
  const suffix = thread.status === "running" ? " · 运行中" : thread.status === "failed" ? " · 失败" : "";
  return button(thread.title + suffix, "select", { id: thread.id }, thread.id === selected ? "secondary" : "ghost");
}
export default definePlugin({
  async deactivate() { await disposeCompletions(); await Promise.all([...stores.values()].map(store => store.dispose())); stores.clear(); },
  capabilities: {
    complete: capability({ record: { request: "string" } }, async (input, host) =>
      completion(input.request, host, await configAt(host.storageDirectory))),
    view: capability({ record: { view: "string", state: "string", event: "string", context: "string" } }, async (input, host) => {
      const context = JSON.parse(input.context); if (!context.storage) throw new Error("Missing plugin storage context");
      let store = stores.get(context.storage);
      if (!store) { store = new Conversations(join(context.storage, "conversations")); stores.set(context.storage, store); }
      const state: { selected?: string; settings?: boolean; error?: string } = input.state ? JSON.parse(input.state) : {};
      const event = input.event ? JSON.parse(input.event) : undefined;
      let config = await configAt(context.storage);
      if (event) state.error = undefined;
      try {
        switch (event?.action) {
          case "new": state.selected = (await store.create(event.arguments?.project || undefined)).id; state.settings = false; break;
          case "select": state.selected = event.arguments.id; state.settings = false; break;
          case "settings": state.settings = !state.settings; break;
          case "draft": {
            if (state.selected) {
              const conversation = await store.get(state.selected);
              if (conversation && conversation.status !== "running") { conversation.draft = String(event.value ?? ""); await store.save(conversation); }
            }
            break;
          }
          case "skill": {
            if (state.selected) {
              const conversation = await store.get(state.selected);
              if (conversation && conversation.status !== "running") {
                conversation.skills = event.value === "none" ? [] : [String(event.value)]; await store.save(conversation);
              }
            }
            break;
          }
          case "configure": {
            const values = event.values ?? {};
            config = { format: values.format ?? config.format, baseURL: values.endpoint ?? config.baseURL, model: values.model ?? config.model, apiKey: values.key || config.apiKey };
            if (!config.model || !config.apiKey) throw new Error("请填写模型和 API Key");
            await saveConfig(context.storage, config); state.settings = false; break;
          }
          case "send": {
            if (!config.apiKey) { state.settings = true; throw new Error("请先配置模型"); }
            const prompt = String(event.values?.[`prompt-${state.selected ?? "new"}`] ?? event.value ?? "").trim(); if (!prompt) break;
            if (!state.selected) state.selected = (await store.create(context.workspace || undefined)).id;
            const selected = await store.get(state.selected); if (!selected) throw new Error("会话不存在");
            const instructions = [selected.project ? `Current project directory: ${selected.project}` : "", await skillInstructions(host, selected.skills ?? [])].join("\n\n");
            const backend = await tools(host, selected.project, selected.id);
            await store.start(selected.id, prompt, (messages, signal, delta) => config.format.startsWith("service:")
              ? generateByService(host, config, messages, signal, delta, selected.project, instructions)
              : generate(config, messages, signal, delta, instructions, backend));
            break;
          }
          case "cancel": if (state.selected) await store.cancel(state.selected); break;
        }
      } catch (error) { state.error = error instanceof Error ? error.message : String(error); }
      const threads = await store.list(); const selected = threads.find(thread => thread.id === state.selected);
      const providers = await extensions(host, "studio.ai.providers/v1");
      const skills = await extensions(host, "studio.ai.skills/v1");
      const standalone = threads.filter(thread => !thread.project);
      const projects = new Map<string, string>((context.projects ?? []).map((p: any) => [p.directory, p.name]));
      for (const thread of threads) if (thread.project && !projects.has(thread.project)) projects.set(thread.project, thread.project.split(/[\\/]/).pop() ?? thread.project);
      const sidebar = column([
        text("Diffuse", "title"), button("新会话", "new", {}, "secondary"), button("模型设置", "settings"),
        ...(standalone.length ? [text("独立会话", "caption", "muted"), ...standalone.map(thread => threadRow(thread, state.selected))] : []),
        text("项目", "caption", "muted"),
        ...[...projects].flatMap(([directory, name]) => [row([text(name, "strong"), button("＋", "new", { project: directory })]),
          ...threads.filter(thread => thread.project === directory).map(thread => threadRow(thread, state.selected))])
      ], { padding: 16, flex: 1 });
      let center: any;
      if (state.settings) {
        center = column([text("模型设置", "title"),
          { type: "select", id: "format", value: config.format.startsWith("service:") && !providers.some(value => `service:${value.data.service}` === config.format) ? "openai-compatible" : config.format, options: [{ value: "openai-compatible", label: "OpenAI compatible" }, { value: "anthropic", label: "Anthropic" }, ...providers.filter(value => value.data.service).map(value => ({ value: `service:${value.data.service}`, label: value.data.title ?? value.id }))] },
          field("endpoint", "API 地址（包含所需的 /v1/ 路径）", config.baseURL), field("model", "模型 ID", config.model), field("key", "API Key", "", true),
          button("保存", "configure", {}, "primary")
        ], { maxWidth: 720, padding: 24 });
      } else {
        const messages = selected?.messages ?? [];
        const history = messages.slice(-40).flatMap(message => [text(message.role === "user" ? "你" : "AI", "caption", "muted"),
          ...Array.from({ length: Math.max(1, Math.ceil(Math.min(message.text.length, 40_000) / 900)) }, (_, index) => text(message.text.slice(index * 1800, (index + 1) * 1800))) ]);
        center = column([
          ...(messages.length ? [{ type: "scroll", child: column(history, { padding: 16, maxWidth: 820 }) }] : [{ type: "spacer" }, text("开始新的工作", "title")]),
          column([
          ...(state.error ? [text(state.error, "caption", "danger")] : []),
          ...(selected ? [text(selected.project ? projects.get(selected.project) ?? selected.project : "独立会话", "caption", "muted")] : []),
          ...(selected && skills.length ? [{ type: "select", id: "skill", value: skills.some(skill => `${skill.pluginID}.${skill.id}` === selected.skills?.[0]) ? selected.skills![0] : "none", action: "skill", options: [{ value: "none", label: "Skill" }, ...skills.map(skill => ({ value: `${skill.pluginID}.${skill.id}`, label: skill.data.title ?? skill.id }))] }] : []),
          { type: "textField", id: `prompt-${state.selected ?? "new"}`, placeholder: "描述你想完成的工作…", multiline: true, minHeight: 88, submit: "send", change: "draft", value: selected?.draft ?? "" },
          row([text(config.model, "caption", "muted"), { type: "spacer" }, selected?.status === "running" ? button("停止", "cancel", {}, "secondary") : button("发送", "send", {}, "primary")])
        ], { padding: 16, background: "raised", cornerRadius: 20, maxWidth: 820 }),
          ...(!messages.length ? [{ type: "spacer" }] : [])
        ], { padding: 32, flex: 1, align: "center" });
      }
      return { state, ui: row([{ type: "scroll", child: sidebar, width: 260, background: "surface", cornerRadius: 16 }, center], { flex: 1 }), refreshAfterMilliseconds: 500 } as unknown as JSONValue;
    })
  }
});
