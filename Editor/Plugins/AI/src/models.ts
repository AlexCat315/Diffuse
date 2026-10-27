import type { Message, ModelConfig } from "./conversations.ts";
export interface ModelTool { type: "function"; function: { name: string; description: string; parameters: any }; readOnly?: boolean; }
export interface ToolBackend { tools: ModelTool[]; invoke(name: string, input: any, signal: AbortSignal): Promise<any>; }

/** SSE parsing belongs to this plugin. The native host has no provider-format switch. */
export async function* events(body: ReadableStream<Uint8Array>): AsyncGenerator<any> {
  const reader = body.getReader(); const decoder = new TextDecoder(); let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      buffer = buffer.replace(/\r\n/g, "\n");
      let end: number;
      while ((end = buffer.indexOf("\n\n")) >= 0) {
        const block = buffer.slice(0, end); buffer = buffer.slice(end + 2);
        const data = block.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
        if (data === "[DONE]") return;
        if (data) yield JSON.parse(data);
      }
      if (done) break;
      if (buffer.length > 1024 * 1024) throw new Error("Model event exceeds limit");
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}
export async function generate(config: ModelConfig, messages: Message[], signal: AbortSignal,
  delta: (text: string) => void, instructions = "", backend?: ToolBackend, maximumTokens = 8192): Promise<void> {
  if (!config.apiKey || !config.model) throw new Error("请先配置模型和 API Key");
  const base = new URL(config.baseURL.endsWith("/") ? config.baseURL : config.baseURL + "/");
  if (!["https:", "http:"].includes(base.protocol) || base.username || base.password) throw new Error("模型地址无效");
  const anthropic = config.format === "anthropic";
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (anthropic) { headers["x-api-key"] = config.apiKey; headers["anthropic-version"] = "2023-06-01"; }
  else headers.authorization = `Bearer ${config.apiKey}`;
  const history: any[] = messages.map(({ role, text }) => ({ role, content: text }));
  for (let turn = 0; turn < 32; turn++) {
  signal.throwIfAborted();
  const tools = backend?.tools ?? [];
  const payload = anthropic ? { model: config.model, max_tokens: maximumTokens, messages: history, stream: true, ...(instructions ? { system: instructions } : {}),
    ...(tools.length ? { tools: tools.map(tool => ({ name: tool.function.name, description: tool.function.description, input_schema: tool.function.parameters })) } : {}) }
    : { model: config.model, max_tokens: maximumTokens, messages: [...(instructions ? [{ role: "system", content: instructions }] : []), ...history], stream: true,
      ...(tools.length ? { tools: tools.map(({ readOnly, ...tool }) => tool) } : {}) };
  const response = await fetch(new URL(anthropic ? "messages" : "chat/completions", base), { method: "POST", headers, body: JSON.stringify(payload), signal });
  if (!response.ok) throw new Error(`模型请求失败 (${response.status}): ${(await response.text()).slice(0, 1000)}`);
  if (!response.body) throw new Error("模型没有返回响应流");
  let answer = "";
  const calls = new Map<number, { id: string; name: string; arguments: string }>();
  for await (const event of events(response.body)) {
    if (signal.aborted) throw signal.reason;
    if (event.error || event.type === "error") throw new Error(event.error?.message ?? "模型返回错误");
    const text = anthropic ? event.delta?.text : event.choices?.[0]?.delta?.content;
    if (typeof text === "string") { answer += text; delta(text); }
    if (anthropic) {
      if (event.type === "content_block_start" && event.content_block?.type === "tool_use") calls.set(event.index, { id: event.content_block.id, name: event.content_block.name, arguments: "" });
      if (event.type === "content_block_delta" && event.delta?.type === "input_json_delta") {
        const call = calls.get(event.index); if (call) call.arguments += event.delta.partial_json;
      }
    } else {
      for (const chunk of event.choices?.[0]?.delta?.tool_calls ?? []) {
        const call = calls.get(chunk.index) ?? { id: "", name: "", arguments: "" };
        call.id += chunk.id ?? ""; call.name += chunk.function?.name ?? ""; call.arguments += chunk.function?.arguments ?? "";
        calls.set(chunk.index, call);
      }
    }
  }
  if (!calls.size) return;
  if (!backend) throw new Error("模型请求了未提供的工具");
  const requested = [...calls.values()].map(call => ({ ...call, input: JSON.parse(call.arguments || "{}") }));
  if (anthropic) history.push({ role: "assistant", content: [ ...(answer ? [{ type: "text", text: answer }] : []), ...requested.map(call => ({ type: "tool_use", id: call.id, name: call.name, input: call.input })) ] });
  else history.push({ role: "assistant", content: answer || null, tool_calls: requested.map(call => ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments || "{}" } })) });
  const results = [];
  for (const call of requested) {
    signal.throwIfAborted();
    let value: unknown;
    try {
      if (!tools.some(tool => tool.function.name === call.name)) throw new Error("Unknown tool");
      value = await backend.invoke(call.name, call.input, signal);
    } catch (error) { if (signal.aborted) throw error; value = { error: error instanceof Error ? error.message : String(error) }; }
    const content = JSON.stringify(value).slice(0, 200_000);
    if (anthropic) results.push({ type: "tool_result", tool_use_id: call.id, content });
    else history.push({ role: "tool", tool_call_id: call.id, content });
  }
  if (anthropic) history.push({ role: "user", content: results });
  }
  throw new Error("此轮已达到 32 次工具循环上限");
}
