import React, { useEffect, useState, useCallback } from "react";
import { useI18n, type Locale } from "../i18n";
import { useConnectionStore } from "../store";

type SettingsTab = "general" | "shortcuts" | "remote";
type FpsDisplay = "viewport" | "none";


// ── Local preferences (stored in localStorage) ───────────────────

const PREFS_KEY = "guava-editor-prefs";

interface EditorPrefs {
  fpsDisplay: FpsDisplay;
  vsyncEnabled: boolean;
}

const defaultPrefs: EditorPrefs = {
  fpsDisplay: "viewport",
  vsyncEnabled: true,
};

function loadPrefs(): EditorPrefs {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (raw) return { ...defaultPrefs, ...JSON.parse(raw) };
  } catch { /* fallback */ }
  return { ...defaultPrefs };
}

function savePrefs(prefs: EditorPrefs) {
  localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
}

// ── Mesh edit shortcut definitions ───────────────────────────────

interface ShortcutBinding {
  key: string;
  ctrl: boolean;
  shift: boolean;
  alt: boolean;
}

interface ShortcutDef {
  id: string;
  label: string;
  labelZh: string;
  default: ShortcutBinding;
}

const MESH_SHORTCUTS: ShortcutDef[] = [
  { id: "extrude",         label: "Extrude",              labelZh: "挤出",           default: { key: "E", ctrl: false, shift: false, alt: false } },
  { id: "inset",           label: "Inset",                labelZh: "内嵌",           default: { key: "I", ctrl: false, shift: false, alt: false } },
  { id: "bevel",           label: "Bevel",                labelZh: "倒角",           default: { key: "B", ctrl: false, shift: false, alt: false } },
  { id: "loopCut",         label: "Loop Cut",             labelZh: "环切",           default: { key: "R", ctrl: true,  shift: false, alt: false } },
  { id: "merge",           label: "Merge",                labelZh: "合并",           default: { key: "M", ctrl: false, shift: false, alt: false } },
  { id: "duplicateFaces",  label: "Duplicate Faces",      labelZh: "复制面",         default: { key: "D", ctrl: false, shift: true,  alt: false } },
  { id: "separateFaces",   label: "Separate Faces",       labelZh: "分离面",         default: { key: "P", ctrl: false, shift: false, alt: false } },
  { id: "recalcNormals",   label: "Recalculate Normals",  labelZh: "重算法线",       default: { key: "N", ctrl: false, shift: true,  alt: false } },
  { id: "pivotToSelection",label: "Pivot To Selection",   labelZh: "轴心到选区",     default: { key: ".", ctrl: false, shift: false, alt: false } },
];

const SHORTCUTS_KEY = "guava-editor-shortcuts";

function loadShortcuts(): Record<string, ShortcutBinding> {
  try {
    const raw = localStorage.getItem(SHORTCUTS_KEY);
    if (raw) return JSON.parse(raw);
  } catch { /* fallback */ }
  const defaults: Record<string, ShortcutBinding> = {};
  for (const s of MESH_SHORTCUTS) defaults[s.id] = { ...s.default };
  return defaults;
}

function saveShortcuts(shortcuts: Record<string, ShortcutBinding>) {
  localStorage.setItem(SHORTCUTS_KEY, JSON.stringify(shortcuts));
}

// ── Component ────────────────────────────────────────────────────

export function SettingsPanel() {
  const connected = useConnectionStore((s) => s.connected);
  const { locale, setLocale, t } = useI18n();
  const [tab, setTab] = useState<SettingsTab>("general");
  const [prefs, setPrefs] = useState<EditorPrefs>(loadPrefs);
  const [shortcuts, setShortcuts] = useState<Record<string, ShortcutBinding>>(loadShortcuts);
  const [recording, setRecording] = useState<string | null>(null);
  const [engineVersion, setEngineVersion] = useState<string>("");

  // Fetch engine version
  useEffect(() => {
    if (!connected) return;
    window.guavaEngine.call("editor.getCapabilities", {})
      .then((res) => setEngineVersion(res.version))
      .catch(() => {});
  }, [connected]);

  const updatePref = useCallback(<K extends keyof EditorPrefs>(key: K, value: EditorPrefs[K]) => {
    setPrefs((prev) => {
      const next = { ...prev, [key]: value };
      savePrefs(next);
      return next;
    });
  }, []);

  const updateShortcut = useCallback((id: string, binding: ShortcutBinding) => {
    setShortcuts((prev) => {
      const next = { ...prev, [id]: binding };
      saveShortcuts(next);
      return next;
    });
  }, []);

  const resetShortcuts = useCallback(() => {
    const defaults: Record<string, ShortcutBinding> = {};
    for (const s of MESH_SHORTCUTS) defaults[s.id] = { ...s.default };
    setShortcuts(defaults);
    saveShortcuts(defaults);
  }, []);

  const handleKeyRecord = useCallback((e: React.KeyboardEvent) => {
    if (!recording) return;
    e.preventDefault();
    e.stopPropagation();
    const key = e.key.length === 1 ? e.key.toUpperCase() : e.key;
    if (["Control", "Shift", "Alt", "Meta"].includes(key)) return; // modifier-only, wait for real key
    updateShortcut(recording, {
      key,
      ctrl: e.ctrlKey || e.metaKey,
      shift: e.shiftKey,
      alt: e.altKey,
    });
    setRecording(null);
  }, [recording, updateShortcut]);

  const isZh = locale === "zh-CN";

  return (
    <div style={styles.container} onKeyDown={handleKeyRecord} tabIndex={0}>
      <div style={styles.header}>{isZh ? "设置" : "Settings"}</div>

      {/* Tab bar */}
      <div style={styles.tabBar}>
        {(["general", "shortcuts", "remote"] as SettingsTab[]).map((t) => (
          <button
            key={t}
            style={{ ...styles.tabButton, ...(tab === t ? styles.tabButtonActive : {}) }}
            onClick={() => setTab(t)}
          >
            {t === "general" ? (isZh ? "通用" : "General")
              : t === "shortcuts" ? (isZh ? "快捷键" : "Shortcuts")
              : (isZh ? "远程服务器" : "Remote Server")}
          </button>
        ))}
      </div>

      <div style={styles.content}>
        {tab === "general" && (
          <GeneralTab
            locale={locale}
            setLocale={setLocale}
            prefs={prefs}
            updatePref={updatePref}
            engineVersion={engineVersion}
            connected={connected}
            isZh={isZh}
          />
        )}
        {tab === "shortcuts" && (
          <ShortcutsTab
            shortcuts={shortcuts}
            recording={recording}
            setRecording={setRecording}
            resetShortcuts={resetShortcuts}
            isZh={isZh}
          />
        )}
        {tab === "remote" && (
          <RemoteServerTab connected={connected} isZh={isZh} />
        )}
      </div>
    </div>
  );
}

// ── General Tab ──────────────────────────────────────────────────

function GeneralTab({
  locale,
  setLocale,
  prefs,
  updatePref,
  engineVersion,
  connected,
  isZh,
}: {
  locale: Locale;
  setLocale: (l: Locale) => void;
  prefs: EditorPrefs;
  updatePref: <K extends keyof EditorPrefs>(key: K, value: EditorPrefs[K]) => void;
  engineVersion: string;
  connected: boolean;
  isZh: boolean;
}) {
  const handleResetLayout = useCallback(() => {
    localStorage.removeItem("guava-editor-layout-v1");
    window.location.reload();
  }, []);

  return (
    <>
      {/* Language */}
      <Section title={isZh ? "语言" : "Language"}>
        <div style={styles.buttonGroup}>
          <button
            style={{ ...styles.optionButton, ...(locale === "en" ? styles.optionButtonActive : {}) }}
            onClick={() => setLocale("en")}
          >
            English
          </button>
          <button
            style={{ ...styles.optionButton, ...(locale === "zh-CN" ? styles.optionButtonActive : {}) }}
            onClick={() => setLocale("zh-CN")}
          >
            中文
          </button>
        </div>
      </Section>

      {/* FPS Display */}
      <Section title={isZh ? "FPS 显示" : "FPS Display"}>
        <div style={styles.buttonGroup}>
          <button
            style={{ ...styles.optionButton, ...(prefs.fpsDisplay === "viewport" ? styles.optionButtonActive : {}) }}
            onClick={() => updatePref("fpsDisplay", "viewport")}
          >
            {isZh ? "视口内显示" : "Viewport"}
          </button>
          <button
            style={{ ...styles.optionButton, ...(prefs.fpsDisplay === "none" ? styles.optionButtonActive : {}) }}
            onClick={() => updatePref("fpsDisplay", "none")}
          >
            {isZh ? "隐藏" : "None"}
          </button>
        </div>
      </Section>

      {/* VSync */}
      <Section title="VSync">
        <label style={styles.toggleRow}>
          <input
            type="checkbox"
            checked={prefs.vsyncEnabled}
            onChange={(e) => updatePref("vsyncEnabled", e.target.checked)}
          />
          <span>{isZh ? "启用垂直同步" : "Enable VSync"}</span>
        </label>
        <div style={styles.hint}>
          {isZh ? "需要引擎端 RPC 支持（即将推出）" : "Requires engine RPC support (coming soon)"}
        </div>
      </Section>

      {/* Layout */}
      <Section title={isZh ? "布局" : "Layout"}>
        <button style={styles.actionButton} onClick={handleResetLayout}>
          {isZh ? "重置面板布局" : "Reset Panel Layout"}
        </button>
      </Section>

      {/* About */}
      <Section title={isZh ? "关于" : "About"}>
        <div style={styles.aboutRow}>
          <span style={styles.aboutLabel}>Guava Engine</span>
          <span style={styles.aboutValue}>{engineVersion || "—"}</span>
        </div>
        <div style={styles.aboutRow}>
          <span style={styles.aboutLabel}>{isZh ? "编辑器" : "Editor"}</span>
          <span style={styles.aboutValue}>Electron</span>
        </div>
        <div style={styles.aboutRow}>
          <span style={styles.aboutLabel}>{isZh ? "连接状态" : "Status"}</span>
          <span style={{ ...styles.aboutValue, color: connected ? "#a6e3a1" : "#f38ba8" }}>
            {connected ? (isZh ? "已连接" : "Connected") : (isZh ? "未连接" : "Disconnected")}
          </span>
        </div>
      </Section>
    </>
  );
}

// ── Shortcuts Tab ────────────────────────────────────────────────

function ShortcutsTab({
  shortcuts,
  recording,
  setRecording,
  resetShortcuts,
  isZh,
}: {
  shortcuts: Record<string, ShortcutBinding>;
  recording: string | null;
  setRecording: (id: string | null) => void;
  resetShortcuts: () => void;
  isZh: boolean;
}) {
  const formatBinding = (b: ShortcutBinding): string => {
    const parts: string[] = [];
    if (b.ctrl) parts.push("Ctrl");
    if (b.shift) parts.push("Shift");
    if (b.alt) parts.push("Alt");
    parts.push(b.key);
    return parts.join("+");
  };

  return (
    <>
      <Section title={isZh ? "网格编辑快捷键" : "Mesh Edit Shortcuts"}>
        <div style={styles.shortcutTable}>
          <div style={styles.shortcutHeaderRow}>
            <span style={styles.shortcutAction}>{isZh ? "操作" : "Action"}</span>
            <span style={styles.shortcutKey}>{isZh ? "快捷键" : "Shortcut"}</span>
            <span style={styles.shortcutRecord} />
          </div>
          {MESH_SHORTCUTS.map((def) => {
            const binding = shortcuts[def.id] || def.default;
            const isRecording = recording === def.id;
            return (
              <div key={def.id} style={{ ...styles.shortcutRow, ...(isRecording ? styles.shortcutRowRecording : {}) }}>
                <span style={styles.shortcutAction}>{isZh ? def.labelZh : def.label}</span>
                <span style={styles.shortcutKey}>
                  {isRecording ? (
                    <span style={styles.recordingBadge}>{isZh ? "录制中..." : "Recording..."}</span>
                  ) : (
                    <code style={styles.keyCode}>{formatBinding(binding)}</code>
                  )}
                </span>
                <span style={styles.shortcutRecord}>
                  <button
                    style={styles.recordButton}
                    onClick={() => setRecording(isRecording ? null : def.id)}
                  >
                    {isRecording ? "✕" : "⌨"}
                  </button>
                </span>
              </div>
            );
          })}
        </div>
        <button style={{ ...styles.actionButton, marginTop: 8 }} onClick={resetShortcuts}>
          {isZh ? "恢复默认快捷键" : "Reset to Defaults"}
        </button>
        <div style={styles.hint}>
          {isZh ? "快捷键保存在本地，后续将同步到引擎端" : "Shortcuts saved locally; engine sync coming soon"}
        </div>
      </Section>
    </>
  );
}

// ── Remote Server Tab ────────────────────────────────────────────

type TestStatus = "idle" | "testing" | "success" | "fail";
type ConnectMode = "local" | "remote";

const REMOTE_URL_KEY = "guava-editor-remote-url";
const CONNECT_MODE_KEY = "guava-editor-connect-mode";

function RemoteServerTab({ connected, isZh }: { connected: boolean; isZh: boolean }) {
  const [url, setUrl] = useState(() => localStorage.getItem(REMOTE_URL_KEY) || "ws://192.168.1.100:9100");
  const [mode, setMode] = useState<ConnectMode>(() => (localStorage.getItem(CONNECT_MODE_KEY) as ConnectMode) || "local");
  const [testStatus, setTestStatus] = useState<TestStatus>("idle");
  const [testResult, setTestResult] = useState("");
  const [connecting, setConnecting] = useState(false);
  const [connectError, setConnectError] = useState("");

  const handleTest = useCallback(async () => {
    setTestStatus("testing");
    setTestResult("");
    try {
      const res = await window.guavaEngine.testRemoteConnection(url);
      if (res.ok) {
        setTestStatus("success");
        setTestResult(res.version ? `Guava Engine v${res.version}` : "Connected");
      } else {
        setTestStatus("fail");
        setTestResult(res.error || "Unknown error");
      }
    } catch (err) {
      setTestStatus("fail");
      setTestResult(String(err));
    }
  }, [url]);

  const handleConnect = useCallback(async (targetMode: ConnectMode) => {
    setConnecting(true);
    setConnectError("");
    try {
      const targetUrl = targetMode === "local" ? "local" : url;
      const res = await window.guavaEngine.connectToServer(targetUrl);
      if (res.ok) {
        setMode(targetMode);
        localStorage.setItem(CONNECT_MODE_KEY, targetMode);
        if (targetMode === "remote") {
          localStorage.setItem(REMOTE_URL_KEY, url);
        }
      } else {
        setConnectError(res.error || "Failed to connect");
      }
    } catch (err) {
      setConnectError(String(err));
    } finally {
      setConnecting(false);
    }
  }, [url]);

  return (
    <>
      {/* Connection Mode */}
      <Section title={isZh ? "连接模式" : "Connection Mode"}>
        <div style={styles.buttonGroup}>
          <button
            style={{ ...styles.optionButton, ...(mode === "local" ? styles.optionButtonActive : {}) }}
            onClick={() => mode !== "local" && handleConnect("local")}
            disabled={connecting}
          >
            {isZh ? "本地引擎" : "Local Engine"}
          </button>
          <button
            style={{ ...styles.optionButton, ...(mode === "remote" ? styles.optionButtonActive : {}) }}
            onClick={() => mode !== "remote" && handleConnect("remote")}
            disabled={connecting}
          >
            {isZh ? "远程服务器" : "Remote Server"}
          </button>
        </div>
        {connecting && (
          <div style={{ ...styles.hint, color: "#89b4fa" }}>
            {isZh ? "正在切换连接..." : "Switching connection..."}
          </div>
        )}
        {connectError && (
          <div style={{ ...styles.hint, color: "#f38ba8" }}>{connectError}</div>
        )}
      </Section>

      {/* Remote Server URL */}
      <Section title={isZh ? "服务器地址" : "Server URL"}>
        <div style={styles.inputRow}>
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="ws://192.168.1.100:9100"
            style={styles.textInput}
          />
        </div>
        <div style={{ display: "flex", gap: 6, marginTop: 6 }}>
          <button style={styles.actionButton} onClick={handleTest} disabled={testStatus === "testing"}>
            {testStatus === "testing"
              ? (isZh ? "测试中..." : "Testing...")
              : (isZh ? "测试连接" : "Test Connection")}
          </button>
        </div>
        {testStatus !== "idle" && testStatus !== "testing" && (
          <div style={{
            ...styles.testResult,
            color: testStatus === "success" ? "#a6e3a1" : "#f38ba8",
            borderColor: testStatus === "success" ? "rgba(166,227,161,0.3)" : "rgba(243,139,168,0.3)",
          }}>
            <span style={{ marginRight: 6 }}>{testStatus === "success" ? "✓" : "✕"}</span>
            {testResult}
          </div>
        )}
      </Section>

      {/* Architecture info */}
      <Section title={isZh ? "架构说明" : "Architecture Notes"}>
        <div style={styles.infoBox}>
          <p style={styles.infoParagraph}>
            {isZh
              ? "远程模式通过 WebSocket RPC 连接到远端引擎服务器。所有面板（层级、检查器、控制台等）均可正常工作。"
              : "Remote mode connects to a remote engine via WebSocket RPC. All panels (hierarchy, inspector, console, etc.) work normally."}
          </p>
          <p style={styles.infoParagraph}>
            {isZh
              ? "⚠️ 视口渲染目前仅支持本地模式（通过共享内存/IOSurface 传输像素）。远程像素流传输（帧编码 + 网络推送）将在后续版本中实现。"
              : "⚠️ Viewport rendering currently works in local mode only (via shared memory/IOSurface). Remote pixel streaming (frame encoding + network push) is planned for a future release."}
          </p>
        </div>
      </Section>

      {/* Status */}
      <Section title={isZh ? "当前状态" : "Current Status"}>
        <div style={styles.aboutRow}>
          <span style={styles.aboutLabel}>{isZh ? "模式" : "Mode"}</span>
          <span style={styles.aboutValue}>
            {mode === "local" ? (isZh ? "本地" : "Local") : (isZh ? "远程" : "Remote")}
          </span>
        </div>
        {mode === "remote" && (
          <div style={styles.aboutRow}>
            <span style={styles.aboutLabel}>{isZh ? "地址" : "URL"}</span>
            <span style={{ ...styles.aboutValue, fontFamily: "monospace", fontSize: 11 }}>{url}</span>
          </div>
        )}
        <div style={styles.aboutRow}>
          <span style={styles.aboutLabel}>{isZh ? "连接" : "Status"}</span>
          <span style={{ ...styles.aboutValue, color: connected ? "#a6e3a1" : "#f38ba8" }}>
            {connected ? (isZh ? "已连接" : "Connected") : (isZh ? "未连接" : "Disconnected")}
          </span>
        </div>
      </Section>
    </>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>{title}</div>
      {children}
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    color: "#cdd6f4",
    fontSize: 13,
    overflow: "auto",
    height: "100%",
    outline: "none",
  },
  header: {
    fontSize: 14,
    fontWeight: 600,
    marginBottom: 8,
    color: "#89b4fa",
  },
  tabBar: {
    display: "flex",
    gap: 2,
    marginBottom: 10,
    borderBottom: "1px solid #313244",
    paddingBottom: 6,
  },
  tabButton: {
    padding: "5px 14px",
    border: "1px solid transparent",
    borderRadius: "4px 4px 0 0",
    background: "transparent",
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 12,
    fontWeight: 500,
  },
  tabButtonActive: {
    background: "#313244",
    color: "#cdd6f4",
    borderColor: "#45475a",
    borderBottomColor: "transparent",
  },
  content: {
    // scrollable content area
  },
  section: {
    marginBottom: 12,
    borderBottom: "1px solid #313244",
    paddingBottom: 8,
  },
  sectionTitle: {
    fontSize: 11,
    textTransform: "uppercase" as const,
    color: "#6c7086",
    letterSpacing: 1,
    marginBottom: 6,
  },
  buttonGroup: {
    display: "flex",
    gap: 4,
  },
  optionButton: {
    flex: 1,
    padding: "5px 10px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 12,
    textAlign: "center" as const,
  },
  optionButtonActive: {
    background: "#89b4fa",
    color: "#1e1e2e",
    borderColor: "#89b4fa",
    fontWeight: 600,
  },
  toggleRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "3px 0",
    cursor: "pointer",
  },
  hint: {
    fontSize: 10,
    color: "#585b70",
    marginTop: 4,
    fontStyle: "italic",
  },
  actionButton: {
    padding: "5px 14px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 12,
  },
  aboutRow: {
    display: "flex",
    justifyContent: "space-between",
    padding: "3px 0",
  },
  aboutLabel: {
    color: "#a6adc8",
    fontSize: 12,
  },
  aboutValue: {
    color: "#cdd6f4",
    fontSize: 12,
    fontWeight: 500,
  },
  // ── Shortcuts table ───────────────────────────────────
  shortcutTable: {
    display: "flex",
    flexDirection: "column",
    gap: 1,
  },
  shortcutHeaderRow: {
    display: "flex",
    alignItems: "center",
    padding: "4px 0",
    borderBottom: "1px solid #45475a",
    fontSize: 11,
    color: "#6c7086",
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
  },
  shortcutRow: {
    display: "flex",
    alignItems: "center",
    padding: "4px 0",
    borderBottom: "1px solid rgba(49,50,68,0.4)",
  },
  shortcutRowRecording: {
    background: "rgba(137,180,250,0.08)",
  },
  shortcutAction: {
    flex: 1,
    fontSize: 12,
  },
  shortcutKey: {
    width: 120,
    textAlign: "center" as const,
  },
  shortcutRecord: {
    width: 32,
    textAlign: "center" as const,
  },
  keyCode: {
    background: "#313244",
    padding: "2px 8px",
    borderRadius: 3,
    fontSize: 11,
    fontFamily: "monospace",
    color: "#cdd6f4",
  },
  recordingBadge: {
    color: "#f38ba8",
    fontSize: 11,
    fontWeight: 600,
  },
  recordButton: {
    background: "transparent",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 11,
    padding: "1px 5px",
    lineHeight: "1",
  },
  // ── Remote server ─────────────────────────────────────
  inputRow: {
    display: "flex",
    gap: 6,
  },
  textInput: {
    flex: 1,
    padding: "5px 8px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 12,
    fontFamily: "monospace",
    outline: "none",
  },
  testResult: {
    marginTop: 6,
    padding: "4px 8px",
    borderRadius: 4,
    border: "1px solid",
    fontSize: 11,
    display: "flex",
    alignItems: "center",
  },
  infoBox: {
    background: "rgba(49,50,68,0.3)",
    border: "1px solid rgba(69,71,90,0.4)",
    borderRadius: 4,
    padding: "6px 8px",
  },
  infoParagraph: {
    fontSize: 11,
    color: "#a6adc8",
    margin: "3px 0",
    lineHeight: 1.5,
  },
};
