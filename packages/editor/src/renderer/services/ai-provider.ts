/**
 * AI provider streaming client — supports OpenAI, Anthropic, Ollama, and Custom endpoints.
 *
 * Runs entirely in the Electron renderer using fetch + ReadableStream.
 */

// ── Types ────────────────────────────────────────────────────────

export type ProviderType = "openai" | "anthropic" | "ollama" | "custom";

export interface ProviderConfig {
  type: ProviderType;
  name: string;
  endpoint: string;
  model: string;
  apiKey: string;
}

export type MessageRole = "user" | "assistant" | "reasoning" | "system";

export interface ChatMessage {
  role: MessageRole;
  content: string;
  timestamp: number;
}

export interface StreamCallbacks {
  onContent: (chunk: string) => void;
  onReasoning?: (chunk: string) => void;
  onDone: (fullContent: string, fullReasoning?: string) => void;
  onError: (error: string) => void;
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
  signal?: AbortSignal,
): Promise<void> {
  const flavor = detectFlavor(config);

  try {
    switch (flavor) {
      case "openai":
        await streamOpenAI(config, messages, systemPrompt, callbacks, signal);
        break;
      case "anthropic":
        await streamAnthropic(config, messages, systemPrompt, callbacks, signal);
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

async function streamOpenAI(
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
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.apiKey}`,
    },
    body: JSON.stringify({
      model: config.model,
      messages: apiMessages,
      stream: true,
      temperature: 0.7,
    }),
    signal,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenAI ${res.status}: ${text.slice(0, 200)}`);
  }

  let fullContent = "";
  let fullReasoning = "";

  await readSSE(res, (data) => {
    if (data === "[DONE]") return;
    try {
      const json = JSON.parse(data);
      const delta = json.choices?.[0]?.delta;
      if (delta?.content) { fullContent += delta.content; cb.onContent(delta.content); }
      if (delta?.reasoning_content) { fullReasoning += delta.reasoning_content; cb.onReasoning?.(delta.reasoning_content); }
    } catch { /* skip malformed */ }
  });

  cb.onDone(fullContent, fullReasoning || undefined);
}

// ── Anthropic ────────────────────────────────────────────────────

async function streamAnthropic(
  config: ProviderConfig,
  messages: ChatMessage[],
  systemPrompt: string | undefined,
  cb: StreamCallbacks,
  signal?: AbortSignal,
) {
  const apiMessages: { role: string; content: string }[] = [];
  for (const m of messages) {
    if (m.role === "reasoning" || m.role === "system") continue;
    apiMessages.push({ role: m.role === "assistant" ? "assistant" : "user", content: m.content });
  }

  const supportsThinking = /claude-(3-7|sonnet-4|opus-4|4)/.test(config.model);
  const body: Record<string, unknown> = {
    model: config.model,
    max_tokens: 4096,
    messages: apiMessages,
    stream: true,
  };
  if (systemPrompt) body.system = systemPrompt;
  if (supportsThinking) body.thinking = { type: "enabled", budget_tokens: 2048 };

  const res = await fetch(config.endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": config.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(body),
    signal,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Anthropic ${res.status}: ${text.slice(0, 200)}`);
  }

  let fullContent = "";
  let fullReasoning = "";
  let currentBlockType = "";

  await readSSE(res, (data) => {
    try {
      const json = JSON.parse(data);
      if (json.type === "content_block_start") {
        currentBlockType = json.content_block?.type ?? "";
      } else if (json.type === "content_block_delta") {
        const delta = json.delta;
        if (delta?.type === "text_delta" && currentBlockType === "text") {
          fullContent += delta.text; cb.onContent(delta.text);
        } else if (delta?.type === "thinking_delta") {
          fullReasoning += delta.thinking; cb.onReasoning?.(delta.thinking);
        }
      }
    } catch { /* skip */ }
  });

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
