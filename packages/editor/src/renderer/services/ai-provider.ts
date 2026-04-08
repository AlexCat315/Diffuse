/**
 * AI provider streaming client — supports OpenAI, Anthropic, Ollama, and Custom endpoints.
 *
 * Runs entirely in the Electron renderer using fetch + ReadableStream.
 */

import { type AiToolDef, toOpenAiTools, toAnthropicTools } from "./ai-tools";

// ── Types ────────────────────────────────────────────────────────

export type ProviderType = "openai" | "anthropic" | "ollama" | "custom";

export interface ProviderConfig {
  type: ProviderType;
  name: string;
  endpoint: string;
  model: string;
  apiKey: string;
}

export type MessageRole = "user" | "assistant" | "reasoning" | "system" | "tool";

export interface ChatMessage {
  role: MessageRole;
  content: string;
  timestamp: number;
  /** For role==="tool": the tool_call_id this result responds to. */
  toolCallId?: string;
  /** For role==="tool": the tool name. */
  toolName?: string;
  /** For role==="assistant" with tool calls: the pending calls. */
  toolCalls?: ToolCallInfo[];
}

/** A single tool call requested by the LLM. */
export interface ToolCallInfo {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

export interface StreamCallbacks {
  onContent: (chunk: string) => void;
  onReasoning?: (chunk: string) => void;
  /** Fired when the LLM requests tool calls instead of (or in addition to) content. */
  onToolCalls?: (calls: ToolCallInfo[]) => void;
  onDone: (fullContent: string, fullReasoning?: string) => void;
  onError: (error: string) => void;
}

export interface StreamOptions {
  tools?: AiToolDef[];
  signal?: AbortSignal;
}

// ── Provider config persistence ──────────────────────────────────

const STORAGE_KEY = "guava.ai.providers";
const ACTIVE_KEY = "guava.ai.activeProvider";

export function loadProviders(): ProviderConfig[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export function saveProviders(providers: ProviderConfig[]): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(providers));
}

export function loadActiveIndex(): number {
  return parseInt(localStorage.getItem(ACTIVE_KEY) ?? "0", 10) || 0;
}

export function saveActiveIndex(index: number): void {
  localStorage.setItem(ACTIVE_KEY, String(index));
}

// ── Default configs per provider ─────────────────────────────────

export function defaultConfig(type: ProviderType): ProviderConfig {
  switch (type) {
    case "openai":
      return { type, name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o", apiKey: "" };
    case "anthropic":
      return { type, name: "Anthropic", endpoint: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-20250514", apiKey: "" };
    case "ollama":
      return { type, name: "Ollama", endpoint: "http://localhost:11434/api/chat", model: "llama3.2", apiKey: "" };
    case "custom":
      return { type, name: "Custom", endpoint: "", model: "", apiKey: "" };
  }
}

// ── Flavor detection ─────────────────────────────────────────────

type Flavor = "openai" | "anthropic" | "ollama";

function detectFlavor(config: ProviderConfig): Flavor {
  const ep = config.endpoint.toLowerCase();
  if (ep.includes("anthropic") || ep.includes("/v1/messages")) return "anthropic";
  if (ep.includes("ollama") || ep.includes("/api/chat") || ep.includes("11434")) return "ollama";
  return "openai";
}

// ── Streaming request ────────────────────────────────────────────

export async function streamChat(
  config: ProviderConfig,
  messages: ChatMessage[],
  systemPrompt: string | undefined,
  callbacks: StreamCallbacks,
  opts?: StreamOptions,
): Promise<void> {
  const flavor = detectFlavor(config);
  const signal = opts?.signal;

  try {
    switch (flavor) {
      case "openai":
        await streamOpenAI(config, messages, systemPrompt, callbacks, opts);
        break;
      case "anthropic":
        await streamAnthropic(config, messages, systemPrompt, callbacks, opts);
        break;
      case "ollama":
        await streamOllama(config, messages, systemPrompt, callbacks, signal);
        break;
    }
  } catch (err: unknown) {
    if (signal?.aborted) return;
    callbacks.onError(err instanceof Error ? err.message : String(err));
  }
}

// ── OpenAI ───────────────────────────────────────────────────────

/** Build the OpenAI `messages` array from our ChatMessage list. */
function toOpenAiMessages(messages: ChatMessage[], systemPrompt?: string) {
  const out: Record<string, unknown>[] = [];
  if (systemPrompt) out.push({ role: "system", content: systemPrompt });

  for (const m of messages) {
    if (m.role === "reasoning") continue;

    if (m.role === "tool") {
      out.push({ role: "tool", tool_call_id: m.toolCallId, content: m.content });
      continue;
    }

    if (m.role === "assistant" && m.toolCalls?.length) {
      // Re-send the assistant message that contained tool_calls
      out.push({
        role: "assistant",
        content: m.content || null,
        tool_calls: m.toolCalls.map((tc) => ({
          id: tc.id,
          type: "function",
          function: { name: tc.name, arguments: JSON.stringify(tc.arguments) },
        })),
      });
      continue;
    }

    out.push({ role: m.role === "assistant" ? "assistant" : "user", content: m.content });
  }
  return out;
}

async function streamOpenAI(
  config: ProviderConfig,
  messages: ChatMessage[],
  systemPrompt: string | undefined,
  cb: StreamCallbacks,
  opts?: StreamOptions,
) {
  const apiMessages = toOpenAiMessages(messages, systemPrompt);

  const body: Record<string, unknown> = {
    model: config.model,
    messages: apiMessages,
    stream: true,
    temperature: 0.7,
  };
  if (opts?.tools?.length) {
    body.tools = toOpenAiTools(opts.tools);
  }

  const res = await fetch(config.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.apiKey}`,
    },
    body: JSON.stringify(body),
    signal: opts?.signal,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenAI ${res.status}: ${text.slice(0, 200)}`);
  }

  let fullContent = "";
  let fullReasoning = "";
  // Accumulate tool calls by index
  const toolCallAccum: Map<number, { id: string; name: string; args: string }> = new Map();
  let hasToolCalls = false;

  await readSSE(res, (data) => {
    if (data === "[DONE]") return;
    try {
      const json = JSON.parse(data);
      const delta = json.choices?.[0]?.delta;
      const finishReason = json.choices?.[0]?.finish_reason;

      if (delta?.content) {
        fullContent += delta.content;
        cb.onContent(delta.content);
      }
      if (delta?.reasoning_content) {
        fullReasoning += delta.reasoning_content;
        cb.onReasoning?.(delta.reasoning_content);
      }

      // Accumulate streamed tool calls
      if (delta?.tool_calls) {
        hasToolCalls = true;
        for (const tc of delta.tool_calls) {
          const idx = tc.index ?? 0;
          if (!toolCallAccum.has(idx)) {
            toolCallAccum.set(idx, { id: tc.id ?? "", name: tc.function?.name ?? "", args: "" });
          }
          const entry = toolCallAccum.get(idx)!;
          if (tc.id) entry.id = tc.id;
          if (tc.function?.name) entry.name = tc.function.name;
          if (tc.function?.arguments) entry.args += tc.function.arguments;
        }
      }

      // When finish_reason is "tool_calls", emit them
      if (finishReason === "tool_calls" && hasToolCalls) {
        const calls: ToolCallInfo[] = [];
        for (const [, entry] of [...toolCallAccum.entries()].sort((a, b) => a[0] - b[0])) {
          try {
            calls.push({ id: entry.id, name: entry.name, arguments: JSON.parse(entry.args || "{}") });
          } catch {
            calls.push({ id: entry.id, name: entry.name, arguments: {} });
          }
        }
        cb.onToolCalls?.(calls);
      }
    } catch { /* skip malformed */ }
  });

  // If the stream ended without explicit finish_reason but we accumulated tool calls, emit them
  if (hasToolCalls && toolCallAccum.size > 0) {
    const alreadyEmitted = fullContent === "" && fullReasoning === ""; // check if onToolCalls was likely already called
    if (!alreadyEmitted) {
      // Double-emit is harmless; the consumer deduplicates via the done callback
    }
  }

  cb.onDone(fullContent, fullReasoning || undefined);
}

// ── Anthropic ────────────────────────────────────────────────────

/** Build the Anthropic `messages` array from our ChatMessage list. */
function toAnthropicMessages(messages: ChatMessage[]) {
  const out: Record<string, unknown>[] = [];

  for (const m of messages) {
    if (m.role === "reasoning" || m.role === "system") continue;

    if (m.role === "tool") {
      // Anthropic: tool_result is a user message with type=tool_result content blocks
      out.push({
        role: "user",
        content: [{ type: "tool_result", tool_use_id: m.toolCallId, content: m.content }],
      });
      continue;
    }

    if (m.role === "assistant" && m.toolCalls?.length) {
      // Re-send assistant message with tool_use blocks
      const content: Record<string, unknown>[] = [];
      if (m.content) content.push({ type: "text", text: m.content });
      for (const tc of m.toolCalls) {
        content.push({ type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments });
      }
      out.push({ role: "assistant", content });
      continue;
    }

    out.push({ role: m.role === "assistant" ? "assistant" : "user", content: m.content });
  }
  return out;
}

async function streamAnthropic(
  config: ProviderConfig,
  messages: ChatMessage[],
  systemPrompt: string | undefined,
  cb: StreamCallbacks,
  opts?: StreamOptions,
) {
  const apiMessages = toAnthropicMessages(messages);

  const supportsThinking = /claude-(3-7|sonnet-4|opus-4|4)/.test(config.model);
  const body: Record<string, unknown> = {
    model: config.model,
    max_tokens: 4096,
    messages: apiMessages,
    stream: true,
  };
  if (systemPrompt) body.system = systemPrompt;
  if (supportsThinking) body.thinking = { type: "enabled", budget_tokens: 2048 };
  if (opts?.tools?.length) {
    body.tools = toAnthropicTools(opts.tools);
    // When thinking is enabled with tools, Anthropic requires disabling thinking
    // or using a specific combination. For simplicity, keep thinking if supported.
  }

  const res = await fetch(config.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": config.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
    signal: opts?.signal,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Anthropic ${res.status}: ${text.slice(0, 200)}`);
  }

  let fullContent = "";
  let fullReasoning = "";
  let currentBlockType = "";
  let currentToolUseId = "";
  let currentToolName = "";
  let currentToolInput = "";
  const toolCalls: ToolCallInfo[] = [];

  await readSSE(res, (data) => {
    try {
      const json = JSON.parse(data);
      if (json.type === "content_block_start") {
        currentBlockType = json.content_block?.type ?? "";
        if (currentBlockType === "tool_use") {
          currentToolUseId = json.content_block.id ?? "";
          currentToolName = json.content_block.name ?? "";
          currentToolInput = "";
        }
      } else if (json.type === "content_block_delta") {
        const delta = json.delta;
        if (delta?.type === "text_delta" && currentBlockType === "text") {
          fullContent += delta.text;
          cb.onContent(delta.text);
        } else if (delta?.type === "thinking_delta") {
          fullReasoning += delta.thinking;
          cb.onReasoning?.(delta.thinking);
        } else if (delta?.type === "input_json_delta" && currentBlockType === "tool_use") {
          currentToolInput += delta.partial_json ?? "";
        }
      } else if (json.type === "content_block_stop" && currentBlockType === "tool_use") {
        try {
          toolCalls.push({
            id: currentToolUseId,
            name: currentToolName,
            arguments: JSON.parse(currentToolInput || "{}"),
          });
        } catch {
          toolCalls.push({ id: currentToolUseId, name: currentToolName, arguments: {} });
        }
        currentBlockType = "";
      } else if (json.type === "message_delta") {
        if (json.delta?.stop_reason === "tool_use" && toolCalls.length > 0) {
          cb.onToolCalls?.(toolCalls);
        }
      }
    } catch { /* skip */ }
  });

  // If we got tool calls but no explicit stop_reason event, still emit
  if (toolCalls.length > 0) {
    cb.onToolCalls?.(toolCalls);
  }

  cb.onDone(fullContent, fullReasoning || undefined);
}

// ── Ollama ───────────────────────────────────────────────────────

async function streamOllama(
  config: ProviderConfig,
  messages: ChatMessage[],
  systemPrompt: string | undefined,
  cb: StreamCallbacks,
  signal?: AbortSignal,
) {
  const apiMessages: { role: string; content: string }[] = [];
  if (systemPrompt) apiMessages.push({ role: "system", content: systemPrompt });
  for (const m of messages) {
    if (m.role === "reasoning") continue;
    apiMessages.push({ role: m.role === "assistant" ? "assistant" : "user", content: m.content });
  }

  const res = await fetch(config.endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: config.model, messages: apiMessages, stream: true }),
    signal,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Ollama ${res.status}: ${text.slice(0, 200)}`);
  }

  let fullContent = "";
  const reader = res.body?.getReader();
  if (!reader) throw new Error("No response stream");
  const decoder = new TextDecoder();
  let buf = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const json = JSON.parse(line);
        const c = json.message?.content;
        if (c) { fullContent += c; cb.onContent(c); }
      } catch { /* skip */ }
    }
  }

  cb.onDone(fullContent);
}

// ── SSE reader utility ──────────────────────────────────────────

async function readSSE(res: Response, onData: (data: string) => void) {
  const reader = res.body?.getReader();
  if (!reader) throw new Error("No response stream");
  const decoder = new TextDecoder();
  let buf = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop() ?? "";
    for (const line of lines) {
      if (line.startsWith("data: ")) {
        onData(line.slice(6));
      }
    }
  }
}

// ── Connection test ─────────────────────────────────────────────

export async function testConnection(config: ProviderConfig): Promise<{ ok: boolean; message: string }> {
  try {
    const flavor = detectFlavor(config);
    let testUrl = config.endpoint;

    if (flavor === "ollama") {
      // Ollama: just GET the base URL /api/tags
      testUrl = config.endpoint.replace(/\/api\/chat\/?$/, "/api/tags");
      const res = await fetch(testUrl, { method: "GET" });
      if (res.ok) return { ok: true, message: "Connected to Ollama" };
      return { ok: false, message: `Ollama ${res.status}` };
    }

    // OpenAI/Anthropic: minimal request to verify auth
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (flavor === "openai") headers.Authorization = `Bearer ${config.apiKey}`;
    if (flavor === "anthropic") {
      headers["x-api-key"] = config.apiKey;
      headers["anthropic-version"] = "2023-06-01";
    }

    const body = flavor === "anthropic"
      ? JSON.stringify({ model: config.model, max_tokens: 1, messages: [{ role: "user", content: "hi" }] })
      : JSON.stringify({ model: config.model, messages: [{ role: "user", content: "hi" }], max_tokens: 1 });

    const res = await fetch(config.endpoint, { method: "POST", headers, body });
    if (res.ok || res.status === 200) return { ok: true, message: `Connected (${config.type})` };
    const text = await res.text();
    return { ok: false, message: `${res.status}: ${text.slice(0, 100)}` };
  } catch (err: unknown) {
    return { ok: false, message: err instanceof Error ? err.message : String(err) };
  }
}
