import React, { useCallback, useEffect, useRef, useState } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";
import { IconCheck, IconClose, IconDelete, IconSettings, IconChevronDown, IconChevronRight } from "../components/Icons";
import {
  type ChatMessage,
  type MessageRole,
  type ProviderConfig,
  type ProviderType,
  type ToolCallInfo,
  defaultConfig,
  loadProviders,
  saveProviders,
  loadActiveIndex,
  saveActiveIndex,
  streamChat,
  testConnection,
} from "../services/ai-provider";
import { AI_TOOLS, findTool } from "../services/ai-tools";
import type { RpcMethodName } from "../../shared/rpc-types";

// ── Role colors ─────────────────────────────────────────────────

const ROLE_COLORS: Record<MessageRole, string> = {
  user: "#89b4fa",
  assistant: "#cdd6f4",
  reasoning: "#cba6f7",
  system: "#a6adc8",
  tool: "#a6e3a1",
};

const ROLE_BG: Record<MessageRole, string> = {
  user: "#1e3a5f",
  assistant: "#1e1e2e",
  reasoning: "#2a1f3d",
  system: "#1e1e2e",
  tool: "#1a2e1a",
};

// ── Tool execution ──────────────────────────────────────────────

const MAX_TOOL_ROUNDS = 15;

async function executeToolCall(call: ToolCallInfo): Promise<string> {
  const def = findTool(call.name);
  if (!def) return JSON.stringify({ error: `Unknown tool: ${call.name}` });

  try {
    const result = await window.guavaEngine.call(
      def.rpcMethod as RpcMethodName,
      call.arguments as never,
    );
    return JSON.stringify(result ?? { ok: true });
  } catch (err: unknown) {
    return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
  }
}

/** Build a system prompt that gives the AI context about available tools and scene state. */
function buildSystemPrompt(): string {
  const categories = new Map<string, string[]>();
  for (const tool of AI_TOOLS) {
    const list = categories.get(tool.category) ?? [];
    list.push(`  - ${tool.name}: ${tool.description}`);
    categories.set(tool.category, list);
  }

  let toolList = "";
  for (const [cat, items] of categories) {
    toolList += `\n[${cat}]\n${items.join("\n")}`;
  }

  return [
    "You are Guava AI — the intelligent assistant embedded in the Guava game engine editor.",
    "You can manipulate the scene, entities, components, scripts, materials, animations, cameras, and playback by calling tools.",
    "When the user asks you to do something to the scene, call the appropriate tool(s). You may call multiple tools in sequence.",
    "Always prefer tool calls over giving instructions — take action directly.",
    "If a tool call fails, report the error to the user and suggest alternatives.",
    "",
    "Available tools:" + toolList,
  ].join("\n");
}

// ── Main component ──────────────────────────────────────────────

export function AiChat() {
  const { t } = useI18n();

  const [messages, setMessages] = useLocalState<ChatMessage[]>([]);
  const [input, setInput] = useLocalState("");
  const [busy, setBusy] = useLocalState(false);
  const [streamContent, setStreamContent] = useLocalState("");
  const [streamReasoning, setStreamReasoning] = useLocalState("");
  const [showSettings, setShowSettings] = useSyncedState("ai-chat", "showSettings", false);
  const [showReasoning, setShowReasoning] = useSyncedState("ai-chat", "showReasoning", true);
  const [toolsEnabled, setToolsEnabled] = useSyncedState("ai-chat", "toolsEnabled", true);

  // Tool confirmation state
  const [pendingConfirm, setPendingConfirm] = useState<{
    calls: ToolCallInfo[];
    resolve: (approved: boolean) => void;
  } | null>(null);

  // Provider state
  const [providers, setProviders] = useLocalState<ProviderConfig[]>(() => loadProviders());
  const [activeIdx, setActiveIdx] = useLocalState(() => loadActiveIndex());
  const [testResult, setTestResult] = useLocalState<{ ok: boolean; message: string } | null>(null);
  const [testing, setTesting] = useLocalState(false);

  const abortRef = useRef<AbortController | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  const activeProvider = providers[activeIdx] ?? null;

  // ── Persist providers ──────────────────────────────────────

  useEffect(() => { saveProviders(providers); }, [providers]);
  useEffect(() => { saveActiveIndex(activeIdx); }, [activeIdx]);

  // ── Auto-scroll ────────────────────────────────────────────

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, streamContent, streamReasoning]);

  // ── Send message ───────────────────────────────────────────

  const send = useCallback(async () => {
    const text = input.trim();
    if (!text || busy || !activeProvider) return;

    const userMsg: ChatMessage = { role: "user", content: text, timestamp: Date.now() };
    let conversationMessages = [...messages, userMsg];
    setMessages(conversationMessages);
    setInput("");
    setBusy(true);
    setStreamContent("");
    setStreamReasoning("");

    const controller = new AbortController();
    abortRef.current = controller;

    const systemPrompt = toolsEnabled ? buildSystemPrompt() : undefined;
    const tools = toolsEnabled ? AI_TOOLS : undefined;

    // Tool-call loop: repeat until the LLM responds with text (no tool calls)
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      if (controller.signal.aborted) break;

      let resolvedContent = "";
      let resolvedReasoning = "";
      // Use a mutable container so TypeScript doesn't narrow to `never` across the closure boundary
      const toolCallBox: { value: ToolCallInfo[] | null } = { value: null };

      // Stream one LLM turn
      await new Promise<void>((resolve) => {
        streamChat(
          activeProvider,
          conversationMessages,
          systemPrompt,
          {
            onContent: (chunk) => {
              resolvedContent += chunk;
              setStreamContent((prev) => prev + chunk);
            },
            onReasoning: (chunk) => {
              resolvedReasoning += chunk;
              setStreamReasoning((prev) => prev + chunk);
            },
            onToolCalls: (calls) => {
              toolCallBox.value = calls;
            },
            onDone: () => resolve(),
            onError: (error) => {
              setMessages((prev) => [
                ...prev,
                { role: "system", content: `Error: ${error}`, timestamp: Date.now() },
              ]);
              setStreamContent("");
              setStreamReasoning("");
              setBusy(false);
              resolve();
            },
          },
          { tools, signal: controller.signal },
        );
      });

      if (controller.signal.aborted) break;

      // Append reasoning if any
      if (resolvedReasoning) {
        const reasoningMsg: ChatMessage = { role: "reasoning", content: resolvedReasoning, timestamp: Date.now() };
        conversationMessages = [...conversationMessages, reasoningMsg];
        setMessages([...conversationMessages]);
      }
      setStreamReasoning("");

      const toolCalls = toolCallBox.value;

      // No tool calls — final text response
      if (!toolCalls || toolCalls.length === 0) {
        const assistantMsg: ChatMessage = { role: "assistant", content: resolvedContent, timestamp: Date.now() };
        conversationMessages = [...conversationMessages, assistantMsg];
        setMessages([...conversationMessages]);
        setStreamContent("");
        setBusy(false);
        return;
      }

      // Got tool calls — add assistant message with toolCalls attached
      const assistantMsg: ChatMessage = {
        role: "assistant",
        content: resolvedContent,
        timestamp: Date.now(),
        toolCalls,
      };
      conversationMessages = [...conversationMessages, assistantMsg];
      setMessages([...conversationMessages]);
      setStreamContent("");

      // Check if any tool requires confirmation
      const needsConfirm = toolCalls.some((tc) => findTool(tc.name)?.requiresConfirmation);
      if (needsConfirm) {
        const approved = await new Promise<boolean>((resolve) => {
          setPendingConfirm({ calls: toolCalls, resolve });
        });
        setPendingConfirm(null);
        if (!approved) {
          // User rejected — add a tool result saying "cancelled by user"
          for (const tc of toolCalls) {
            const cancelMsg: ChatMessage = {
              role: "tool",
              content: JSON.stringify({ error: "Cancelled by user" }),
              timestamp: Date.now(),
              toolCallId: tc.id,
              toolName: tc.name,
            };
            conversationMessages = [...conversationMessages, cancelMsg];
          }
          setMessages([...conversationMessages]);
          setBusy(false);
          return;
        }
      }

      // Execute tool calls
      for (const tc of toolCalls) {
        const result = await executeToolCall(tc);
        const toolMsg: ChatMessage = {
          role: "tool",
          content: result,
          timestamp: Date.now(),
          toolCallId: tc.id,
          toolName: tc.name,
        };
        conversationMessages = [...conversationMessages, toolMsg];
        setMessages([...conversationMessages]);
      }

      // Loop back — send tool results to LLM for next turn
    }

    // If we hit MAX_TOOL_ROUNDS, notify
    setMessages((prev) => [
      ...prev,
      { role: "system", content: "Tool call limit reached. Please try a simpler request.", timestamp: Date.now() },
    ]);
    setBusy(false);
  }, [input, busy, activeProvider, messages, toolsEnabled]);

  // ── Stop generation ────────────────────────────────────────

  const stop = useCallback(() => {
    abortRef.current?.abort();
    setBusy(false);
    if (streamContent) {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: streamContent + " [stopped]", timestamp: Date.now() },
      ]);
      setStreamContent("");
      setStreamReasoning("");
    }
  }, [streamContent]);

  // ── Clear history ──────────────────────────────────────────

  const clearHistory = useCallback(() => {
    setMessages([]);
    setStreamContent("");
    setStreamReasoning("");
  }, []);

  // ── Provider management ────────────────────────────────────

  const addProvider = useCallback((type: ProviderType) => {
    setProviders((prev) => [...prev, defaultConfig(type)]);
    setActiveIdx(providers.length);
    setTestResult(null);
  }, [providers.length]);

  const updateProvider = useCallback((idx: number, updates: Partial<ProviderConfig>) => {
    setProviders((prev) => prev.map((p, i) => i === idx ? { ...p, ...updates } : p));
    setTestResult(null);
  }, []);

  const removeProvider = useCallback((idx: number) => {
    setProviders((prev) => prev.filter((_, i) => i !== idx));
    if (activeIdx >= idx && activeIdx > 0) setActiveIdx(activeIdx - 1);
    setTestResult(null);
  }, [activeIdx]);

  const doTest = useCallback(async () => {
    if (!activeProvider) return;
    setTesting(true);
    const result = await testConnection(activeProvider);
    setTestResult(result);
    setTesting(false);
  }, [activeProvider]);

  // ── Key handler ────────────────────────────────────────────

  const onKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  }, [send]);

  // ── Settings panel ─────────────────────────────────────────

  if (showSettings) {
    return (
      <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <div style={styles.toolbar}>
          <span style={styles.toolbarTitle}>{t.aiChat.providerSettings}</span>
          <button style={styles.toolbarBtn} onClick={() => setShowSettings(false)}>
            ← {t.aiChat.backToChat}
          </button>
        </div>
        <div style={{ flex: 1, overflow: "auto", padding: 12 }}>
          {/* Add provider */}
          <div style={{ marginBottom: 12 }}>
            <label style={styles.fieldLabel}>{t.aiChat.addProvider}</label>
            <div style={{ display: "flex", gap: 4, marginTop: 4 }}>
              {(["openai", "anthropic", "ollama", "custom"] as ProviderType[]).map((type) => (
                <button key={type} style={styles.toolbarBtn} onClick={() => addProvider(type)}>
                  + {type}
                </button>
              ))}
            </div>
          </div>

          {/* Provider list */}
          {providers.map((p, i) => (
            <div
              key={i}
              style={{
                border: `1px solid ${i === activeIdx ? "#89b4fa" : "#45475a"}`,
                borderRadius: 6,
                padding: 10,
                marginBottom: 8,
                background: i === activeIdx ? "#1e1e2e" : "#181825",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                <span style={{ fontWeight: 600, fontSize: 12, color: "#cdd6f4" }}>
                  {p.type.toUpperCase()}{i === activeIdx ? <> <IconCheck size={10} /></> : ""}
                </span>
                <div style={{ display: "flex", gap: 4 }}>
                  {i !== activeIdx && (
                    <button style={styles.smallBtn} onClick={() => { setActiveIdx(i); setTestResult(null); }}>
                      {t.aiChat.activate}
                    </button>
                  )}
                  <button style={{ ...styles.smallBtn, color: "#f38ba8" }} onClick={() => removeProvider(i)}>
                    <IconClose size={10} />
                  </button>
                </div>
              </div>

              <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                <div>
                  <label style={styles.fieldLabel}>{t.aiChat.name}</label>
                  <input
                    style={styles.input}
                    value={p.name}
                    onChange={(e) => updateProvider(i, { name: e.target.value })}
                  />
                </div>
                <div>
                  <label style={styles.fieldLabel}>{t.aiChat.endpoint}</label>
                  <input
                    style={styles.input}
                    value={p.endpoint}
                    onChange={(e) => updateProvider(i, { endpoint: e.target.value })}
                  />
                </div>
                <div>
                  <label style={styles.fieldLabel}>{t.aiChat.model}</label>
                  <input
                    style={styles.input}
                    value={p.model}
                    onChange={(e) => updateProvider(i, { model: e.target.value })}
                  />
                </div>
                {p.type !== "ollama" && (
                  <div>
                    <label style={styles.fieldLabel}>API Key</label>
                    <input
                      style={styles.input}
                      type="password"
                      value={p.apiKey}
                      onChange={(e) => updateProvider(i, { apiKey: e.target.value })}
                    />
                  </div>
                )}
              </div>
            </div>
          ))}

          {/* Test connection */}
          {activeProvider && (
            <div style={{ marginTop: 8 }}>
              <button style={styles.toolbarBtn} onClick={doTest} disabled={testing}>
                {testing ? "..." : t.aiChat.testConnection}
              </button>
              {testResult && (
                <span style={{ marginLeft: 8, fontSize: 11, color: testResult.ok ? "#a6e3a1" : "#f38ba8" }}>
                  {testResult.message}
                </span>
              )}
            </div>
          )}

          {providers.length === 0 && (
            <div style={styles.emptyHint}>{t.aiChat.noProviders}</div>
          )}
        </div>
      </div>
    );
  }

  // ── Chat view ──────────────────────────────────────────────

  return (
    <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column" }}>
      {/* Toolbar */}
      <div style={styles.toolbar}>
        <span style={styles.toolbarTitle}>{t.aiChat.title}</span>
        {activeProvider && (
          <span style={{ fontSize: 10, color: "#a6adc8" }}>
            {activeProvider.name} ({activeProvider.model})
          </span>
        )}
        <div style={{ flex: 1 }} />
        <button
          style={{
            ...styles.toolbarBtn,
            background: toolsEnabled ? "#1e3a5f" : "#313244",
            color: toolsEnabled ? "#89b4fa" : "#6c7086",
          }}
          onClick={() => setToolsEnabled(!toolsEnabled)}
          title={toolsEnabled ? "Tools enabled — AI can control the engine" : "Tools disabled — chat only"}
        >
          🔧 {toolsEnabled ? "ON" : "OFF"}
        </button>
        <button style={styles.toolbarBtn} onClick={clearHistory} title={t.aiChat.clear}>
          <IconDelete size={14} />
        </button>
        <button style={styles.toolbarBtn} onClick={() => setShowSettings(true)}>
          <IconSettings size={14} /> {t.aiChat.settings}
        </button>
      </div>

      {/* Confirmation dialog */}
      {pendingConfirm && (
        <div style={styles.confirmBar}>
          <span style={{ fontSize: 11, color: "#f9e2af" }}>
            ⚠️ AI wants to execute destructive action(s): {pendingConfirm.calls.map((c) => c.name).join(", ")}
          </span>
          <div style={{ display: "flex", gap: 4, marginTop: 4 }}>
            <button
              style={{ ...styles.toolbarBtn, background: "#a6e3a1", color: "#1e1e2e" }}
              onClick={() => pendingConfirm.resolve(true)}
            >
              Approve
            </button>
            <button
              style={{ ...styles.toolbarBtn, background: "#f38ba8", color: "#1e1e2e" }}
              onClick={() => pendingConfirm.resolve(false)}
            >
              Reject
            </button>
          </div>
        </div>
      )}

      {/* Messages */}
      <div ref={scrollRef} style={styles.messageArea}>
        {messages.length === 0 && !streamContent && (
          <div style={styles.emptyHint}>
            {activeProvider ? t.aiChat.emptyChat : t.aiChat.configureFirst}
          </div>
        )}

        {messages.map((msg, i) => {
          if (msg.role === "reasoning" && !showReasoning) return null;

          // Tool call message — assistant with toolCalls
          if (msg.role === "assistant" && msg.toolCalls?.length) {
            return (
              <div key={i} style={{ ...styles.msgCard, background: "#1a2636" }}>
                <div style={styles.msgHeader}>
                  <span style={{ color: "#89b4fa", fontWeight: 600, fontSize: 10 }}>TOOL CALLS</span>
                  <span style={{ fontSize: 9, color: "#585b70", marginLeft: "auto" }}>
                    {new Date(msg.timestamp).toLocaleTimeString()}
                  </span>
                </div>
                {msg.content && <div style={styles.msgBody}>{msg.content}</div>}
                <div style={{ marginTop: 4 }}>
                  {msg.toolCalls.map((tc, j) => (
                    <div key={j} style={styles.toolCallChip}>
                      <span style={{ color: "#89b4fa", fontWeight: 600 }}>⚡ {tc.name}</span>
                      <span style={{ color: "#a6adc8", fontSize: 10, marginLeft: 6 }}>
                        {JSON.stringify(tc.arguments)}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            );
          }

          // Tool result message
          if (msg.role === "tool") {
            let parsed: unknown;
            try { parsed = JSON.parse(msg.content); } catch { parsed = msg.content; }
            const isError = typeof parsed === "object" && parsed !== null && "error" in parsed;
            return (
              <div key={i} style={{ ...styles.msgCard, background: isError ? "#2a1a1a" : "#1a2e1a" }}>
                <div style={styles.msgHeader}>
                  <span style={{ color: isError ? "#f38ba8" : "#a6e3a1", fontWeight: 600, fontSize: 10 }}>
                    {isError ? "✗" : "✓"} {msg.toolName ?? "TOOL RESULT"}
                  </span>
                  <span style={{ fontSize: 9, color: "#585b70", marginLeft: "auto" }}>
                    {new Date(msg.timestamp).toLocaleTimeString()}
                  </span>
                </div>
                <div style={{ ...styles.msgBody, fontSize: 10, maxHeight: 120, overflow: "auto" }}>
                  {typeof parsed === "string" ? parsed : JSON.stringify(parsed, null, 2)}
                </div>
              </div>
            );
          }

          return (
            <div key={i} style={{ ...styles.msgCard, background: ROLE_BG[msg.role] }}>
              <div style={styles.msgHeader}>
                <span style={{ color: ROLE_COLORS[msg.role], fontWeight: 600, fontSize: 10 }}>
                  {msg.role.toUpperCase()}
                </span>
                {msg.role === "reasoning" && (
                  <button
                    style={styles.smallBtn}
                    onClick={() => setShowReasoning(!showReasoning)}
                  >
                    {showReasoning ? <IconChevronDown size={10} /> : <IconChevronRight size={10} />}
                  </button>
                )}
                <span style={{ fontSize: 9, color: "#585b70", marginLeft: "auto" }}>
                  {new Date(msg.timestamp).toLocaleTimeString()}
                </span>
              </div>
              <div style={styles.msgBody}>{msg.content}</div>
            </div>
          );
        })}

        {/* Streaming preview */}
        {streamReasoning && (
          <div style={{ ...styles.msgCard, background: ROLE_BG.reasoning, opacity: 0.8 }}>
            <div style={styles.msgHeader}>
              <span style={{ color: ROLE_COLORS.reasoning, fontWeight: 600, fontSize: 10 }}>THINKING…</span>
            </div>
            <div style={styles.msgBody}>{streamReasoning}</div>
          </div>
        )}
        {streamContent && (
          <div style={{ ...styles.msgCard, background: ROLE_BG.assistant, opacity: 0.8 }}>
            <div style={styles.msgHeader}>
              <span style={{ color: ROLE_COLORS.assistant, fontWeight: 600, fontSize: 10 }}>ASSISTANT…</span>
            </div>
            <div style={styles.msgBody}>{streamContent}▊</div>
          </div>
        )}
      </div>

      {/* Input area */}
      <div style={styles.inputArea}>
        <textarea
          style={styles.textarea}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder={activeProvider ? t.aiChat.placeholder : t.aiChat.configureFirst}
          disabled={!activeProvider}
          rows={2}
        />
        <div style={{ display: "flex", gap: 4, padding: "4px 0" }}>
          {busy ? (
            <button style={{ ...styles.toolbarBtn, background: "#f38ba8" }} onClick={stop}>
              {t.aiChat.stop}
            </button>
          ) : (
            <button
              style={styles.toolbarBtn}
              onClick={send}
              disabled={!input.trim() || !activeProvider}
            >
              {t.aiChat.send}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  toolbar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "6px 10px",
    borderBottom: "1px solid #313244",
    background: "#181825",
  },
  toolbarTitle: {
    fontWeight: 600,
    fontSize: 12,
    color: "#cdd6f4",
  },
  toolbarBtn: {
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 4,
    padding: "3px 10px",
    fontSize: 11,
    cursor: "pointer",
  },
  smallBtn: {
    background: "none",
    border: "none",
    color: "#89b4fa",
    cursor: "pointer",
    fontSize: 10,
    padding: "0 4px",
  },
  messageArea: {
    flex: 1,
    overflow: "auto",
    padding: 8,
  },
  msgCard: {
    borderRadius: 6,
    padding: "6px 10px",
    marginBottom: 6,
    border: "1px solid #313244",
  },
  msgHeader: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    marginBottom: 2,
  },
  msgBody: {
    fontSize: 12,
    color: "#cdd6f4",
    whiteSpace: "pre-wrap",
    wordBreak: "break-word",
    lineHeight: 1.5,
  },
  inputArea: {
    borderTop: "1px solid #313244",
    padding: "6px 10px",
    background: "#181825",
  },
  textarea: {
    width: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 6,
    padding: "8px 10px",
    fontSize: 12,
    resize: "vertical",
    outline: "none",
    fontFamily: "inherit",
  },
  fieldLabel: {
    display: "block",
    color: "#a6adc8",
    fontSize: 10,
    marginBottom: 2,
  },
  input: {
    width: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 3,
    padding: "4px 6px",
    fontSize: 11,
  },
  emptyHint: {
    color: "#585b70",
    fontSize: 12,
    textAlign: "center",
    padding: 24,
    fontStyle: "italic",
  },
  confirmBar: {
    padding: "8px 12px",
    background: "#2a2000",
    borderBottom: "1px solid #f9e2af44",
  },
  toolCallChip: {
    display: "flex",
    alignItems: "center",
    background: "#181825",
    borderRadius: 4,
    padding: "3px 8px",
    marginTop: 3,
    fontSize: 11,
    border: "1px solid #313244",
  },
};
