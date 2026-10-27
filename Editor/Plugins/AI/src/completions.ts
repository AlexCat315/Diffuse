import type { InvocationContext, JSONValue } from "@diffuse/plugin-sdk";
import type { ModelConfig } from "./conversations.ts";
import { generate } from "./models.ts";
import { generateByService } from "./extensions.ts";
const jobs = new Map<string, { controller: AbortController; task: Promise<void>; text: string; done: boolean; error?: string }>();
export async function completion(request: string, host: InvocationContext, config: ModelConfig): Promise<JSONValue> {
  const input = JSON.parse(request);
  if (input.operation === "start") {
    if (jobs.size >= 32) throw new Error("Too many active completions");
    if (typeof input.prompt !== "string" || typeof input.instructions !== "string") throw new Error("Invalid completion");
    const handle = crypto.randomUUID();
    const job = { controller: new AbortController(), task: Promise.resolve(), text: "", done: false, error: undefined as string | undefined };
    jobs.set(handle, job);
    const messages = [{ id: handle, role: "user" as const, text: input.prompt }];
    const delta = (chunk: string) => { job.text += chunk; };
    job.task = (config.format.startsWith("service:")
      ? generateByService(host, config, messages, job.controller.signal, delta, undefined, input.instructions)
      : generate(config, messages, job.controller.signal, delta, input.instructions, undefined, Math.min(8192, Math.max(1, Number(input.maxTokens) || 8192))))
      .catch(error => { job.error = error instanceof Error ? error.message : String(error); })
      .finally(() => { job.done = true; });
    return { handle };
  }
  const job = jobs.get(input.handle); if (!job) throw new Error("Completion is unavailable");
  if (input.operation === "cancel") { job.controller.abort(); jobs.delete(input.handle); return null; }
  if (input.operation !== "poll") throw new Error("Unknown completion operation");
  if (job.done) jobs.delete(input.handle);
  return { done: job.done, text: job.text, ...(job.error ? { error: job.error } : {}) };
}
export async function disposeCompletions() {
  const active = [...jobs.values()]; active.forEach(job => job.controller.abort());
  await Promise.allSettled(active.map(job => job.task)); jobs.clear();
}
