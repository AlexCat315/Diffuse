import React, { useCallback, useEffect, useRef } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";
import {
  type ChatMessage,
  type MessageRole,
  type ProviderConfig,
  type ProviderType,
  defaultConfig,
  loadProviders,
  saveProviders,
  loadActiveIndex,
  saveActiveIndex,
  streamChat,
  testConnection,
} from "../services/ai-provider";

// ── Role colors ─────────────────────────────────────────────────

const ROLE_COLORS: Record<MessageRole, string> = {
  user: "#89b4fa",
  assistant: "#cdd6f4",
  reasoning: "#cba6f7",
  system: "#a6adc8",
};

const ROLE_BG: Record<MessageRole, string> = {
  user: "#1e3a5f",
  assistant: "#1e1e2e",
  reasoning: "#2a1f3d",
  system: "#1e1e2e",
};

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
    const newMessages = [...messages, userMsg];
    setMessages(newMessages);
    setInput("");
    setBusy(true);
    setStreamContent("");
    setStreamReasoning("");

    const controller = new AbortController();
    abortRef.current = controller;

    await streamChat(
      activeProvider,
      newMessages,
      undefined,
      {
        onContent: (chunk) => setStreamContent((prev) => prev + chunk),
        onReasoning: (chunk) => setStreamReasoning((prev) => prev + chunk),
        onDone: (content, reasoning) => {
          const newMsgs: ChatMessage[] = [];
          if (reasoning) {
            newMsgs.push({ role: "reasoning", content: reasoning, timestamp: Date.now() });
          }
          newMsgs.push({ role: "assistant", content, timestamp: Date.now() });
          setMessages((prev) => [...prev, ...newMsgs]);
          setStreamContent("");
          setStreamReasoning("");
          setBusy(false);
        },
        onError: (error) => {
          setMessages((prev) => [
            ...prev,
            { role: "system", content: `Error: ${error}`, timestamp: Date.now() },
          ]);
          setStreamContent("");
          setStreamReasoning("");
          setBusy(false);
        },
      },
      controller.signal,
    );
  }, [input, busy, activeProvider, messages]);

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
                  {p.type.toUpperCase()}{i === activeIdx ? " ✓" : ""}
                </span>
                <div style={{ display: "flex", gap: 4 }}>
                  {i !== activeIdx && (
                    <button style={styles.smallBtn} onClick={() => { setActiveIdx(i); setTestResult(null); }}>
                      {t.aiChat.activate}
                    </button>
                  )}
                  <button style={{ ...styles.smallBtn, color: "#f38ba8" }} onClick={() => removeProvider(i)}>
                    ✕
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
        <button style={styles.toolbarBtn} onClick={clearHistory} title={t.aiChat.clear}>
          🗑
        </button>
        <button style={styles.toolbarBtn} onClick={() => setShowSettings(true)}>
          ⚙ {t.aiChat.settings}
        </button>
      </div>

      {/* Messages */}
      <div ref={scrollRef} style={styles.messageArea}>
        {messages.length === 0 && !streamContent && (
          <div style={styles.emptyHint}>
            {activeProvider ? t.aiChat.emptyChat : t.aiChat.configureFirst}
          </div>
        )}

        {messages.map((msg, i) => {
          if (msg.role === "reasoning" && !showReasoning) return null;
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
                    {showReasoning ? "▼" : "▶"}
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
};
