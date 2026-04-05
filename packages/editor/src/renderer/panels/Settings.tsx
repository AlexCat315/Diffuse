import React, { useEffect, useCallback, useRef, useMemo } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n, type Locale } from "../i18n";
import { useConnectionStore, useViewportSettingsStore, useConsoleStore } from "../store";
import { useSyncedState } from "../store/synced-state";

// ── Local preferences (stored in localStorage) ───────────────────

const PREFS_KEY = "guava-editor-prefs";

interface EditorPrefs {
  vsyncEnabled: boolean;
}

const defaultPrefs: EditorPrefs = {
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
  { id: "extrude",         label: "Extrude",              labelZh: "挤出",       default: { key: "E", ctrl: false, shift: false, alt: false } },
  { id: "inset",           label: "Inset",                labelZh: "内嵌",       default: { key: "I", ctrl: false, shift: false, alt: false } },
  { id: "bevel",           label: "Bevel",                labelZh: "倒角",       default: { key: "B", ctrl: false, shift: false, alt: false } },
  { id: "loopCut",         label: "Loop Cut",             labelZh: "环切",       default: { key: "R", ctrl: true,  shift: false, alt: false } },
  { id: "merge",           label: "Merge",                labelZh: "合并",       default: { key: "M", ctrl: false, shift: false, alt: false } },
  { id: "duplicateFaces",  label: "Duplicate Faces",      labelZh: "复制面",     default: { key: "D", ctrl: false, shift: true,  alt: false } },
  { id: "separateFaces",   label: "Separate Faces",       labelZh: "分离面",     default: { key: "P", ctrl: false, shift: false, alt: false } },
  { id: "recalcNormals",   label: "Recalculate Normals",  labelZh: "重算法线",   default: { key: "N", ctrl: false, shift: true,  alt: false } },
  { id: "pivotToSelection",label: "Pivot To Selection",   labelZh: "轴心到选区", default: { key: ".", ctrl: false, shift: false, alt: false } },
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

// ── Section nav definitions ──────────────────────────────────────

interface SectionDef {
  id: string;
  label: string;
  labelZh: string;
  icon: string;
  keywords: string[];
  advanced?: boolean;
}

const SECTIONS: SectionDef[] = [
  { id: "language",   label: "Language",    labelZh: "语言",       icon: "🌐", keywords: ["language", "locale", "english", "中文", "语言"] },
  { id: "appearance", label: "Appearance",  labelZh: "外观",       icon: "◉",  keywords: ["fps", "display", "vsync", "overlay", "显示", "垂直同步", "帧率"] },
  { id: "console",    label: "Console",     labelZh: "控制台",     icon: "▸",  keywords: ["console", "log", "max", "limit", "控制台", "日志", "上限"] },
  { id: "layout",     label: "Layout",      labelZh: "布局",       icon: "⊞",  keywords: ["layout", "panel", "reset", "布局", "面板", "重置"] },
  { id: "shortcuts",  label: "Shortcuts",   labelZh: "快捷键",     icon: "⌨",  keywords: ["shortcut", "key", "binding", "mesh", "extrude", "bevel", "快捷键", "网格"] },
  { id: "remote",     label: "Remote",      labelZh: "远程服务器", icon: "☁",  keywords: ["remote", "server", "local", "websocket", "connect", "远程", "服务器", "连接"], advanced: true },
  { id: "about",      label: "About",       labelZh: "关于",       icon: "ⓘ",  keywords: ["version", "engine", "status", "about", "版本", "关于"] },
];

// ── Remote server constants ──────────────────────────────────────

type TestStatus = "idle" | "testing" | "success" | "fail";
type ConnectMode = "local" | "remote";

const REMOTE_URL_KEY = "guava-editor-remote-url";
const CONNECT_MODE_KEY = "guava-editor-connect-mode";

// ── Main Component ───────────────────────────────────────────────

export function SettingsPanel() {
  const connected = useConnectionStore((s) => s.connected);
  const fpsLimit = useViewportSettingsStore((s) => s.fpsLimit);
  const setFpsLimit = useViewportSettingsStore((s) => s.setFpsLimit);
  const fpsDisplay = useViewportSettingsStore((s) => s.fpsDisplay);
  const setFpsDisplay = useViewportSettingsStore((s) => s.setFpsDisplay);
  const { locale, setLocale, t } = useI18n();
  const isZh = locale === "zh-CN";

  const [prefs, setPrefs] = useLocalState<EditorPrefs>(loadPrefs);
  const [shortcuts, setShortcuts] = useLocalState<Record<string, ShortcutBinding>>(loadShortcuts);
  const [recording, setRecording] = useLocalState<string | null>(null);
  const [engineVersion, setEngineVersion] = useLocalState<string>("");
  const [search, setSearch] = useLocalState("");
  const [showAdvanced, setShowAdvanced] = useSyncedState("settings", "showAdvanced", false);
  const [activeSection, setActiveSection] = useSyncedState("settings", "activeSection", "language");
  const maxLogs = useConsoleStore((s) => s.maxLogs);
  const setMaxLogs = useConsoleStore((s) => s.setMaxLogs);
  const contentRef = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Record<string, HTMLDivElement | null>>({});

  const [remoteUrl, setRemoteUrl] = useLocalState(() => localStorage.getItem(REMOTE_URL_KEY) || "ws://192.168.1.100:9100");
  const [connectMode, setConnectMode] = useLocalState<ConnectMode>(() => (localStorage.getItem(CONNECT_MODE_KEY) as ConnectMode) || "local");
  const [testStatus, setTestStatus] = useLocalState<TestStatus>("idle");
  const [testResult, setTestResult] = useLocalState("");
  const [connecting, setConnecting] = useLocalState(false);
  const [connectError, setConnectError] = useLocalState("");

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
    if (["Control", "Shift", "Alt", "Meta"].includes(key)) return;
    updateShortcut(recording, {
      key,
      ctrl: e.ctrlKey || e.metaKey,
      shift: e.shiftKey,
      alt: e.altKey,
    });
    setRecording(null);
  }, [recording, updateShortcut]);

  const formatBinding = (b: ShortcutBinding): string => {
    const parts: string[] = [];
    if (b.ctrl) parts.push("Ctrl");
    if (b.shift) parts.push("Shift");
    if (b.alt) parts.push("Alt");
    parts.push(b.key);
    return parts.join("+");
  };

  const handleResetLayout = useCallback(() => {
    localStorage.removeItem("guava-editor-layout-v3");
    window.location.reload();
  }, []);

  const handleTest = useCallback(async () => {
    setTestStatus("testing");
    setTestResult("");
    try {
      const res = await window.guavaEngine.testRemoteConnection(remoteUrl);
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
  }, [remoteUrl]);

  const handleConnect = useCallback(async (targetMode: ConnectMode) => {
    setConnecting(true);
    setConnectError("");
    try {
      const targetUrl = targetMode === "local" ? "local" : remoteUrl;
      const res = await window.guavaEngine.connectToServer(targetUrl);
      if (res.ok) {
        setConnectMode(targetMode);
        localStorage.setItem(CONNECT_MODE_KEY, targetMode);
        if (targetMode === "remote") {
          localStorage.setItem(REMOTE_URL_KEY, remoteUrl);
        }
      } else {
        setConnectError(res.error || "Failed to connect");
      }
    } catch (err) {
      setConnectError(String(err));
    } finally {
      setConnecting(false);
    }
  }, [remoteUrl]);

  const q = search.toLowerCase().trim();
  const visibleSections = useMemo(() => {
    let sections = showAdvanced ? SECTIONS : SECTIONS.filter((s) => !s.advanced);
    if (q) {
      sections = sections.filter((s) =>
        s.label.toLowerCase().includes(q) ||
        s.labelZh.includes(q) ||
        s.keywords.some((kw) => kw.includes(q)),
      );
    }
    return sections;
  }, [q, showAdvanced]);
  const visibleIds = useMemo(() => new Set(visibleSections.map((s) => s.id)), [visibleSections]);

  const scrollToSection = useCallback((id: string) => {
    setActiveSection(id);
    sectionRefs.current[id]?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, []);

  useEffect(() => {
    const el = contentRef.current;
    if (!el) return;
    const handler = () => {
      const scrollTop = el.scrollTop;
      let closest = SECTIONS[0]?.id;
      for (const s of SECTIONS) {
        const ref = sectionRefs.current[s.id];
        if (ref && ref.offsetTop - el.offsetTop <= scrollTop + 40) {
          closest = s.id;
        }
      }
      if (closest) setActiveSection(closest);
    };
    el.addEventListener("scroll", handler, { passive: true });
    return () => el.removeEventListener("scroll", handler);
  }, []);

  return (
    <div style={S.root} onKeyDown={handleKeyRecord} tabIndex={0}>
      {/* Search bar */}
      <div style={S.searchBar}>
        <span style={S.searchIcon}>&#x2315;</span>
        <input
          style={S.searchInput}
          placeholder={(isZh ? "搜索设置" : "Search settings") + "..."}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {search && (
          <button style={S.searchClear} onClick={() => setSearch("")}>&#x2715;</button>
        )}
        <button
          style={{ ...S.advancedToggle, ...(showAdvanced ? S.advancedToggleOn : {}) }}
          onClick={() => setShowAdvanced((v) => !v)}
          title={isZh ? "显示高级设置" : "Show advanced settings"}
        >
          {isZh ? "高级" : "Advanced"}
        </button>
      </div>

      <div style={S.body}>
        {/* Left nav */}
        <nav style={S.nav}>
          {SECTIONS.map((s) => {
            const visible = visibleIds.has(s.id);
            if (!visible && q) return null;
            return (
              <button
                key={s.id}
                style={{
                  ...S.navItem,
                  ...(activeSection === s.id ? S.navItemActive : {}),
                  ...(visible ? {} : { opacity: 0.3 }),
                }}
                onClick={() => scrollToSection(s.id)}
              >
                <span style={S.navIcon}>{s.icon}</span>
                <span style={S.navLabel}>{isZh ? s.labelZh : s.label}</span>
              </button>
            );
          })}
        </nav>

        {/* Center content */}
        <div ref={contentRef} style={S.content}>

          {visibleIds.has("language") && (
            <div ref={(el) => { sectionRefs.current["language"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "语言" : "Language"}</div>
              <SettingRow label={isZh ? "界面语言" : "Interface Language"} desc={isZh ? "选择编辑器显示语言" : "Editor display language"}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(locale === "en" ? S.btnActive : {}) }} onClick={() => setLocale("en")}>English</button>
                  <button style={{ ...S.btn, ...(locale === "zh-CN" ? S.btnActive : {}) }} onClick={() => setLocale("zh-CN")}>中文</button>
                </div>
              </SettingRow>
            </div>
          )}

          {visibleIds.has("appearance") && (
            <div ref={(el) => { sectionRefs.current["appearance"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "外观" : "Appearance"}</div>
              <SettingRow label={isZh ? "FPS 显示" : "FPS Display"} desc={isZh ? "在视口中显示帧率叠加层" : "Show frame rate overlay in viewport"}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(fpsDisplay === "viewport" ? S.btnActive : {}) }} onClick={() => setFpsDisplay("viewport")}>{isZh ? "视口内" : "Viewport"}</button>
                  <button style={{ ...S.btn, ...(fpsDisplay === "none" ? S.btnActive : {}) }} onClick={() => setFpsDisplay("none")}>{isZh ? "隐藏" : "None"}</button>
                </div>
              </SettingRow>
              <SettingRow label={isZh ? "帧率上限" : "Frame Rate Limit"} desc={isZh ? "限制引擎渲染帧率" : "Limit engine rendering frame rate"}>
                <div style={S.btnGroup}>
                  {[30, 60, 90, 120].map((fps) => (
                    <button key={fps} style={{ ...S.btn, ...(fpsLimit === fps ? S.btnActive : {}) }} onClick={() => setFpsLimit(fps)}>{fps}</button>
                  ))}
                </div>
              </SettingRow>
              <SettingRow label="VSync" desc={isZh ? "启用垂直同步（需引擎端支持）" : "Enable vertical sync (requires engine support)"}>
                <Toggle checked={prefs.vsyncEnabled} onChange={(v) => updatePref("vsyncEnabled", v)} />
              </SettingRow>
            </div>
          )}

          {visibleIds.has("console") && (
            <div ref={(el) => { sectionRefs.current["console"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "控制台" : "Console"}</div>
              <SettingRow label={isZh ? "最大日志条数" : "Max Log Entries"} desc={isZh ? "超过此数量时，最旧的日志将被丢弃（50–10000）" : "Oldest entries are discarded when the limit is exceeded (50–10,000)"}>
                <input
                  type="number"
                  min={50}
                  max={10000}
                  step={50}
                  value={maxLogs}
                  onChange={(e) => {
                    const v = parseInt(e.target.value, 10);
                    if (Number.isFinite(v)) setMaxLogs(v);
                  }}
                  style={S.numberInput}
                />
              </SettingRow>
            </div>
          )}

          {visibleIds.has("layout") && (
            <div ref={(el) => { sectionRefs.current["layout"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "布局" : "Layout"}</div>
              <SettingRow label={isZh ? "面板布局" : "Panel Layout"} desc={isZh ? "恢复默认面板排列方式" : "Restore default panel arrangement"}>
                <button style={S.actionBtn} onClick={handleResetLayout}>{isZh ? "重置布局" : "Reset Layout"}</button>
              </SettingRow>
            </div>
          )}

          {visibleIds.has("shortcuts") && (
            <div ref={(el) => { sectionRefs.current["shortcuts"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "快捷键" : "Shortcuts"}</div>
              <div style={S.subsectionTitle}>{isZh ? "网格编辑" : "Mesh Editing"}</div>
              <div style={S.shortcutTable}>
                <div style={S.shortcutHeaderRow}>
                  <span style={S.shortcutAction}>{isZh ? "操作" : "Action"}</span>
                  <span style={S.shortcutKey}>{isZh ? "快捷键" : "Shortcut"}</span>
                  <span style={S.shortcutRecord} />
                </div>
                {MESH_SHORTCUTS.map((def) => {
                  const binding = shortcuts[def.id] || def.default;
                  const isRec = recording === def.id;
                  return (
                    <div key={def.id} style={{ ...S.shortcutRow, ...(isRec ? S.shortcutRowRecording : {}) }}>
                      <span style={S.shortcutAction}>{isZh ? def.labelZh : def.label}</span>
                      <span style={S.shortcutKey}>
                        {isRec ? (
                          <span style={S.recordingBadge}>{isZh ? "录制中..." : "Recording..."}</span>
                        ) : (
                          <code style={S.keyCode}>{formatBinding(binding)}</code>
                        )}
                      </span>
                      <span style={S.shortcutRecord}>
                        <button style={S.recordBtn} onClick={() => setRecording(isRec ? null : def.id)}>
                          {isRec ? "\u2715" : "\u2328"}
                        </button>
                      </span>
                    </div>
                  );
                })}
              </div>
              <div style={{ marginTop: 8, display: "flex", gap: 8, alignItems: "center" }}>
                <button style={S.actionBtn} onClick={resetShortcuts}>{isZh ? "恢复默认" : "Reset to Defaults"}</button>
                <span style={S.hint}>{isZh ? "快捷键保存在本地" : "Saved locally"}</span>
              </div>
            </div>
          )}

          {visibleIds.has("remote") && (
            <div ref={(el) => { sectionRefs.current["remote"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "远程服务器" : "Remote Server"}</div>
              <SettingRow label={isZh ? "连接模式" : "Connection Mode"} desc={isZh ? "选择本地引擎或远端服务器" : "Local engine or remote server"}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(connectMode === "local" ? S.btnActive : {}) }} onClick={() => connectMode !== "local" && handleConnect("local")} disabled={connecting}>{isZh ? "本地" : "Local"}</button>
                  <button style={{ ...S.btn, ...(connectMode === "remote" ? S.btnActive : {}) }} onClick={() => connectMode !== "remote" && handleConnect("remote")} disabled={connecting}>{isZh ? "远程" : "Remote"}</button>
                </div>
              </SettingRow>
              {connecting && <div style={{ ...S.hint, color: "#89b4fa" }}>{isZh ? "正在切换连接..." : "Switching..."}</div>}
              {connectError && <div style={{ ...S.hint, color: "#f38ba8" }}>{connectError}</div>}
              <SettingRow label={isZh ? "服务器地址" : "Server URL"}>
                <div style={{ display: "flex", gap: 6 }}>
                  <input type="text" value={remoteUrl} onChange={(e) => setRemoteUrl(e.target.value)} placeholder="ws://192.168.1.100:9100" style={S.textInput} />
                  <button style={S.actionBtn} onClick={handleTest} disabled={testStatus === "testing"}>
                    {testStatus === "testing" ? (isZh ? "测试..." : "Test...") : (isZh ? "测试" : "Test")}
                  </button>
                </div>
              </SettingRow>
              {testStatus !== "idle" && testStatus !== "testing" && (
                <div style={{ ...S.testResult, color: testStatus === "success" ? "#a6e3a1" : "#f38ba8", borderColor: testStatus === "success" ? "rgba(166,227,161,0.3)" : "rgba(243,139,168,0.3)" }}>
                  <span style={{ marginRight: 6 }}>{testStatus === "success" ? "\u2713" : "\u2715"}</span>
                  {testResult}
                </div>
              )}
              <div style={S.infoBox}>
                <p style={S.infoParagraph}>
                  {isZh ? "远程模式通过 WebSocket RPC 连接到远端引擎服务器。所有面板均可正常工作。" : "Remote mode connects via WebSocket RPC. All panels work normally."}
                </p>
                <p style={S.infoParagraph}>
                  {isZh ? "⚠️ 视口渲染仅支持本地模式（IOSurface）。远程像素流传输计划于后续版本实现。" : "⚠️ Viewport rendering is local-only (IOSurface). Remote streaming is planned."}
                </p>
              </div>
            </div>
          )}

          {visibleIds.has("about") && (
            <div ref={(el) => { sectionRefs.current["about"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{isZh ? "关于" : "About"}</div>
              <div style={S.aboutGrid}>
                <AboutRow label="Guava Engine" value={engineVersion || "\u2014"} />
                <AboutRow label={isZh ? "编辑器" : "Editor"} value="Electron" />
                <AboutRow label={isZh ? "连接状态" : "Status"} value={connected ? (isZh ? "已连接" : "Connected") : (isZh ? "未连接" : "Disconnected")} valueColor={connected ? "#a6e3a1" : "#f38ba8"} />
                {connectMode === "remote" && <AboutRow label={isZh ? "地址" : "URL"} value={remoteUrl} mono />}
              </div>
            </div>
          )}

          {visibleSections.length === 0 && (
            <div style={S.empty}>{isZh ? "没有匹配的设置" : "No matching settings"}</div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function SettingRow({ label, desc, children }: { label: string; desc?: string; children: React.ReactNode }) {
  return (
    <div style={S.settingRow}>
      <div style={S.settingMeta}>
        <span style={S.settingLabel}>{label}</span>
        {desc && <span style={S.settingDesc}>{desc}</span>}
      </div>
      <div style={S.settingControl}>{children}</div>
    </div>
  );
}

function Toggle({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      style={{ ...S.toggle, ...(checked ? S.toggleOn : {}) }}
      onClick={() => onChange(!checked)}
      role="switch"
      aria-checked={checked}
    >
      <span style={{ ...S.toggleThumb, ...(checked ? S.toggleThumbOn : {}) }} />
    </button>
  );
}

function AboutRow({ label, value, valueColor, mono }: { label: string; value: string; valueColor?: string; mono?: boolean }) {
  return (
    <div style={S.aboutRow}>
      <span style={S.aboutLabel}>{label}</span>
      <span style={{ ...S.aboutValue, ...(valueColor ? { color: valueColor } : {}), ...(mono ? { fontFamily: "monospace", fontSize: 11 } : {}) }}>{value}</span>
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const S: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    minHeight: 0,
    color: "#cdd6f4",
    fontSize: 13,
    background: "#1e1e2e",
    outline: "none",
  },
  empty: {
    opacity: 0.4,
    textAlign: "center",
    padding: 32,
    fontSize: 12,
  },
  searchBar: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    padding: "6px 10px",
    borderBottom: "1px solid #313244",
    background: "#181825",
    flexShrink: 0,
  },
  searchIcon: {
    fontSize: 14,
    color: "#6c7086",
    flexShrink: 0,
  },
  searchInput: {
    flex: 1,
    background: "transparent",
    border: "none",
    outline: "none",
    color: "#cdd6f4",
    fontSize: 12,
    padding: 0,
  },
  searchClear: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 11,
    padding: "0 2px",
  },
  advancedToggle: {
    flexShrink: 0,
    padding: "2px 8px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "transparent",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 10,
    whiteSpace: "nowrap" as const,
    transition: "all 0.1s",
  },
  advancedToggleOn: {
    color: "#89b4fa",
    borderColor: "#89b4fa",
    background: "rgba(137,180,250,0.1)",
  },
  body: {
    display: "flex",
    flex: 1,
    minHeight: 0,
    overflow: "hidden",
  },
  nav: {
    width: 140,
    flexShrink: 0,
    borderRight: "1px solid #313244",
    padding: "6px 0",
    overflowY: "auto" as const,
    background: "#181825",
  },
  navItem: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    width: "100%",
    padding: "5px 12px",
    border: "none",
    background: "transparent",
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 11,
    textAlign: "left" as const,
    borderLeft: "2px solid transparent",
    transition: "all 0.1s",
  },
  navItemActive: {
    color: "#89b4fa",
    background: "rgba(137, 180, 250, 0.08)",
    borderLeftColor: "#89b4fa",
  },
  navIcon: {
    fontSize: 13,
    width: 16,
    textAlign: "center" as const,
    flexShrink: 0,
  },
  navLabel: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  content: {
    flex: 1,
    overflowY: "auto" as const,
    padding: "0 16px 24px",
  },
  section: {
    paddingTop: 14,
    marginBottom: 4,
  },
  sectionHeader: {
    fontSize: 11,
    fontWeight: 700,
    textTransform: "uppercase" as const,
    letterSpacing: 1,
    color: "#89b4fa",
    marginBottom: 8,
    paddingBottom: 4,
    borderBottom: "1px solid #313244",
  },
  subsectionTitle: {
    fontSize: 11,
    color: "#a6adc8",
    fontWeight: 600,
    marginBottom: 4,
  },
  settingRow: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "7px 0",
    minHeight: 32,
    borderBottom: "1px solid rgba(49, 50, 68, 0.4)",
  },
  settingMeta: {
    display: "flex",
    flexDirection: "column" as const,
    gap: 1,
    flex: 1,
    minWidth: 0,
  },
  settingLabel: {
    fontSize: 12,
    color: "#cdd6f4",
  },
  settingDesc: {
    fontSize: 10,
    color: "#6c7086",
    lineHeight: "1.3",
  },
  settingControl: {
    flexShrink: 0,
    marginLeft: 12,
  },
  btnGroup: {
    display: "flex",
    gap: 2,
  },
  btn: {
    padding: "3px 10px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 11,
    transition: "all 0.1s",
    whiteSpace: "nowrap" as const,
  },
  btnActive: {
    background: "#89b4fa",
    color: "#1e1e2e",
    borderColor: "#89b4fa",
    fontWeight: 600,
  },
  actionBtn: {
    padding: "4px 12px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 11,
    whiteSpace: "nowrap" as const,
  },
  numberInput: {
    width: 72,
    padding: "3px 6px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 11,
    textAlign: "right" as const,
  },
  toggle: {
    position: "relative" as const,
    width: 32,
    height: 18,
    borderRadius: 9,
    border: "1px solid #45475a",
    background: "#313244",
    cursor: "pointer",
    padding: 0,
    transition: "all 0.15s",
  },
  toggleOn: {
    background: "#89b4fa",
    borderColor: "#89b4fa",
  },
  toggleThumb: {
    position: "absolute" as const,
    top: 2,
    left: 2,
    width: 12,
    height: 12,
    borderRadius: "50%",
    background: "#6c7086",
    transition: "all 0.15s",
  },
  toggleThumbOn: {
    left: 16,
    background: "#1e1e2e",
  },
  shortcutTable: {
    display: "flex",
    flexDirection: "column" as const,
    gap: 1,
  },
  shortcutHeaderRow: {
    display: "flex",
    alignItems: "center",
    padding: "4px 0",
    borderBottom: "1px solid #45475a",
    fontSize: 10,
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
  recordBtn: {
    background: "transparent",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 11,
    padding: "1px 5px",
    lineHeight: "1",
  },
  hint: {
    fontSize: 10,
    color: "#585b70",
    fontStyle: "italic",
  },
  textInput: {
    flex: 1,
    padding: "4px 8px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 11,
    fontFamily: "monospace",
    outline: "none",
    minWidth: 180,
  },
  testResult: {
    marginTop: 4,
    padding: "3px 8px",
    borderRadius: 4,
    border: "1px solid",
    fontSize: 11,
    display: "flex",
    alignItems: "center",
  },
  infoBox: {
    marginTop: 8,
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
  aboutGrid: {
    display: "flex",
    flexDirection: "column" as const,
    gap: 2,
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
};
