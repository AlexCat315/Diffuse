import { hostJob, type InvocationContext } from "@diffuse/plugin-sdk";
import type { Message, ModelConfig } from "./conversations.ts";
import { authoring, authoringTools } from "./authoring.ts";
import type { ToolBackend } from "./models.ts";

export interface Extension { pluginID: string; id: string; data: { title?: string; service?: string; resource?: string; instructions?: string; name?: string; description?: string; parameters?: any; readOnly?: boolean }; }
export async function extensions(context: InvocationContext, point: string): Promise<Extension[]> {
  return await context.query("cove:service/host", { operation: "extensions", point }) as unknown as Extension[];
}
export async function skillInstructions(context: InvocationContext, selected: string[]): Promise<string> {
  const available = await extensions(context, "studio.ai.skills/v1"); const sections: string[] = [];
  for (const skill of available.filter(skill => selected.includes(`${skill.pluginID}.${skill.id}`))) {
    let instructions = skill.data.instructions ?? "";
    if (skill.data.resource) {
      const value = await context.query("cove:service/host", { operation: "resource", pluginID: skill.pluginID, id: skill.data.resource }) as { text: string };
      instructions += value.text;
    }
    if (Buffer.byteLength(instructions) > 64 * 1024) throw new Error("Skill instructions exceed limit");
    sections.push(instructions);
  }
  return sections.join("\n\n");
}
export async function tools(context: InvocationContext, workspace: string | undefined, conversation: string): Promise<ToolBackend> {
  const native = workspace ? await context.query("diffuse:editor/host", { operation: "tools", workspace }) as any[] : [];
  const contributed = (await extensions(context, "studio.ai.tools/v1")).filter(value => value.data.service && value.data.name && value.data.parameters);
  const byName = new Map(contributed.map(value => [value.data.name!, value]));
  return {
    tools: [...authoringTools, ...native, ...contributed.map(value => ({ type: "function" as const, readOnly: value.data.readOnly ?? false,
      function: { name: value.data.name!, description: value.data.description ?? value.data.title ?? value.id, parameters: value.data.parameters } }))],
    async invoke(name, input, signal) {
      if (authoringTools.some(tool => tool.function.name === name)) return authoring(name, input, context, signal);
      const extension = byName.get(name);
      if (extension) return hostJob(context, "cove:service/host", { service: extension.data.service!, input: { conversation, workspace: workspace ?? "", arguments: input } }, signal);
      if (!workspace) throw new Error("此工具需要项目");
      return hostJob(context, "diffuse:editor/host", { workspace, conversation, message: { action: "project_tool", tool_name: name, arguments: input } }, signal);
    }
  };
}

/** A provider extension owns its protocol and streams through its own scoped handle. */
export async function generateByService(context: InvocationContext, config: ModelConfig, messages: Message[], signal: AbortSignal,
  delta: (text: string) => void, workspace?: string, instructions = ""): Promise<void> {
  const service = config.format.slice("service:".length);
  const invoke = (input: any, currentSignal = signal) => hostJob(context, "cove:service/host", { service, input }, currentSignal) as Promise<any>;
  const started = await invoke({ operation: "start", config, messages, workspace: workspace ?? "", instructions });
  if (!started.handle) throw new Error("Provider did not return a stream handle");
  let finished = false;
  try {
    while (true) {
      signal.throwIfAborted();
      const output = await invoke({ operation: "poll", handle: started.handle });
      for (const chunk of output.chunks ?? []) if (typeof chunk === "string") delta(chunk);
      if (output.error) throw new Error(output.error);
      if (output.done) { finished = true; return; }
      await Bun.sleep(100);
    }
  } finally {
    if (!finished) await invoke({ operation: "cancel", handle: started.handle }, new AbortController().signal).catch(() => {});
  }
}
