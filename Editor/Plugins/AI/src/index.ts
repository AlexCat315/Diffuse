import { capability, definePlugin, type JSONValue } from "@diffuse/plugin-sdk";
import { mkdir, readFile, writeFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { Conversations, type Conversation, type ModelConfig } from "./conversations.ts";
import { generate } from "./models.ts";
import { extensions, skillInstructions, tools, generateByService } from "./extensions.ts";

import { completion, disposeCompletions } from "./completions.ts";

const stores = new Map<string, Conversations>();
type ViewState = { selected?: string; settings?: boolean; error?: string };
const views = new Map<string, ViewState>();
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
  return { ...button(thread.title + suffix, "select", { id: thread.id }, thread.id === selected ? "secondary" : "ghost"), align: "start" };
}
export default definePlugin({
  async deactivate() { await disposeCompletions(); await Promise.all([...stores.values()].map(store => store.dispose())); stores.clear(); views.clear(); },
  capabilities: {
    conversation: capability({ record: { request: "string" } }, async (input, host) => {
      const request = JSON.parse(input.request);
      if (request.operation !== "current") throw new Error("Unknown conversation operation");
      const selected = views.get(host.storageDirectory)?.selected;
      const store = stores.get(host.storageDirectory);
      const conversation = selected && store ? await store.get(selected) : undefined;
      if (!conversation) return null;
      return { id: conversation.id, title: conversation.title, project: conversation.project ?? null,
        status: conversation.status, skills: conversation.skills ?? [],
        messages: conversation.messages.slice(-20).map(message => ({ role: message.role, text: message.text.slice(-16_000) })) };
    }),
    complete: capability({ record: { request: "string" } }, async (input, host) =>
      completion(input.request, host, await configAt(host.storageDirectory))),
    view: capability({ record: { view: "string", state: "string", event: "string", context: "string" } }, async (input, host) => {
      const context = JSON.parse(input.context); if (!context.storage) throw new Error("Missing plugin storage context");
      let store = stores.get(context.storage);
      if (!store) { store = new Conversations(join(context.storage, "conversations")); stores.set(context.storage, store); }
      const state = views.get(context.storage) ?? (input.state ? JSON.parse(input.state) : {}) as ViewState;
      views.set(context.storage, state);
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
            if (!config.model || (!config.format.startsWith("service:") && !config.apiKey)) throw new Error("请填写模型和 API Key");
            await saveConfig(context.storage, config); state.settings = false; break;
          }
          case "send": {
            if (!config.format.startsWith("service:") && !config.apiKey) { state.settings = true; throw new Error("请先配置模型"); }
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
        text("Diffuse", "title"), button("新会话", "new", {}, "secondary"), button("模型设置", "settings", {}, state.settings ? "secondary" : "ghost"),
        ...(standalone.length ? [text("独立会话", "caption", "muted"), ...standalone.map(thread => threadRow(thread, state.selected))] : []),
        text("项目", "caption", "muted"),
        ...[...projects].flatMap(([directory, name]) => [row([text(name, "strong"), button("＋", "new", { project: directory })]),
          ...threads.filter(thread => thread.project === directory).map(thread => threadRow(thread, state.selected))])
      ], { padding: 20, flex: 1 });
      const project = selected ? selected.project : context.workspace;
      let center: any;
      if (state.settings) {
        center = column([text("模型设置", "title"),
          { type: "select", id: "format", value: config.format.startsWith("service:") && !providers.some(value => `service:${value.data.service}` === config.format) ? "openai-compatible" : config.format, options: [{ value: "openai-compatible", label: "OpenAI compatible" }, { value: "anthropic", label: "Anthropic" }, ...providers.filter(value => value.data.service).map(value => ({ value: `service:${value.data.service}`, label: value.data.title ?? value.id }))] },
          text("服务地址", "caption", "muted"), field("endpoint", "API 地址（包含所需的 /v1/ 路径）", config.baseURL),
          text("模型", "caption", "muted"), field("model", "模型 ID", config.model),
          text("API Key", "caption", "muted"), field("key", "API Key", "", true),
          button("保存", "configure", {}, "primary")
        ], { fillWidth: true, maxWidth: 720, padding: 24 });
      } else {
        const messages = selected?.messages ?? [];
        const history = messages.slice(-40).flatMap(message => {
          const visible = message.text.slice(-40_000);
          return [text(message.role === "user" ? "你" : "AI", "caption", "muted"),
            ...Array.from({ length: Math.max(1, Math.ceil(visible.length / 900)) }, (_, index) => text(visible.slice(index * 900, (index + 1) * 900)))];
        });
        center = column([
          ...(messages.length ? [{ type: "scroll", child: column(history, { padding: 16, fillWidth: true, maxWidth: 820 }), fillWidth: true }] : [{ type: "spacer" }, text("开始新的工作", "title")]),
          column([
          ...(state.error ? [text(state.error, "caption", "danger")] : []),
          text(project ? projects.get(project) ?? project.split(/[\\/]/).pop() : "独立会话", "caption", "muted"),
          ...(selected && skills.length ? [{ type: "select", id: "skill", value: skills.some(skill => `${skill.pluginID}.${skill.id}` === selected.skills?.[0]) ? selected.skills![0] : "none", action: "skill", options: [{ value: "none", label: "Skill" }, ...skills.map(skill => ({ value: `${skill.pluginID}.${skill.id}`, label: skill.data.title ?? skill.id }))] }] : []),
          { type: "textField", id: `prompt-${state.selected ?? "new"}`, placeholder: "描述你想完成的工作…", multiline: true, minHeight: 88, submit: "send", change: "draft", value: selected?.draft ?? "" },
          row([text(config.model, "caption", "muted"), { type: "spacer" }, selected?.status === "running" ? button("停止", "cancel", {}, "secondary") : button("发送", "send", {}, "primary")])
        ], { padding: 16, background: "raised", cornerRadius: 20, fillWidth: true, maxWidth: 820 }),
          ...(!messages.length ? [{ type: "spacer" }] : [])
        ], { padding: 32, spacing: messages.length ? 12 : 24, flex: 1, align: "center" });
      }
      const details = column([
        text("上下文", "strong"),
        text("项目", "caption", "muted"), text(project ? projects.get(project) ?? project : "独立会话"),
        ...(project ? [text(project, "caption", "muted")] : []),
        text("模型", "caption", "muted"), text(config.model),
        ...(selected ? [text("会话状态", "caption", "muted"), text(({ idle: "未开始", running: "运行中", completed: "已完成", cancelled: "已停止", failed: "失败", interrupted: "已中断" })[selected.status])] : []),
        ...(selected?.skills?.length ? [text("Skills", "caption", "muted"), ...selected.skills.map(id => text(skills.find(skill => `${skill.pluginID}.${skill.id}` === id)?.data.title as string ?? id))] : [])
      ], { padding: 20 });
      const ui = input.view === "ai-conversations" ? { type: "scroll", child: sidebar }
        : input.view === "ai-context" ? { type: "scroll", child: details } : center;
      return { state, ui, refreshAfterMilliseconds: 500 } as unknown as JSONValue;
    })
  }
});
