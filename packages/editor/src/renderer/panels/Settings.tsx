import React, { useEffect, useCallback, useRef, useMemo } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n, type Locale } from "../i18n";
import { useConnectionStore, useViewportSettingsStore, useConsoleStore } from "../store";
import { useSyncedState } from "../store/synced-state";
import { IconGlobe, IconGrid, IconChevronRight, IconSettings, IconRemote, IconAbout } from "../components/Icons";
import { engine } from "../engine-client";

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

// ── Section nav definitions ──────────────────────────────────────

interface SectionDef {
  id: string;
  label: string;
  icon: React.ReactNode;
  keywords: string[];
  advanced?: boolean;
}

const SECTIONS: SectionDef[] = [
  { id: "language",   label: "Language",   icon: <IconGlobe size={14} />, keywords: ["language", "locale", "english", "中文", "语言"] },
  { id: "appearance", label: "Appearance", icon: <IconSettings size={14} />,  keywords: ["fps", "display", "vsync", "overlay", "显示", "垂直同步", "帧率"] },
  { id: "console",    label: "Console",    icon: <IconChevronRight size={14} />,  keywords: ["console", "log", "max", "limit", "控制台", "日志", "上限"] },
  { id: "layout",     label: "Layout",     icon: <IconGrid size={14} />,  keywords: ["layout", "panel", "reset", "布局", "面板", "重置"] },
  { id: "remote",     label: "Remote",     icon: <IconRemote size={14} />,  keywords: ["remote", "server", "local", "websocket", "connect", "远程", "服务器", "连接"], advanced: true },
  { id: "about",      label: "About",      icon: <IconAbout size={14} />,  keywords: ["version", "engine", "status", "about", "版本", "关于"] },
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

  const navLabels: Record<string, string> = {
    language: t.settings.navLanguage,
    appearance: t.settings.navAppearance,
    console: t.settings.navConsole,
    layout: t.settings.navLayout,
    remote: t.settings.navRemote,
    about: t.settings.navAbout,
  };

  const [prefs, setPrefs] = useLocalState<EditorPrefs>(loadPrefs);
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
    engine.call("editor.getCapabilities", {})
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

  const handleResetLayout = useCallback(() => {
    localStorage.removeItem("guava-editor-layout-v3");
    window.location.reload();
  }, []);

  const handleTest = useCallback(async () => {
    setTestStatus("testing");
    setTestResult("");
    try {
      const res = await engine.test(remoteUrl);
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
      let res: { ok: boolean; error?: string };
      try {
        if (targetUrl === "local") {
          engine.connect();
        } else {
          engine.connect(targetUrl);
        }
        res = { ok: true };
      } catch (err) {
        res = { ok: false, error: err instanceof Error ? err.message : String(err) };
      }
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
    <div style={S.root} tabIndex={0}>
      {/* Search bar */}
      <div style={S.searchBar}>
        <span style={S.searchIcon}>&#x2315;</span>
        <input
          style={S.searchInput}
          placeholder={t.settings.searchPlaceholder}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {search && (
          <button style={S.searchClear} onClick={() => setSearch("")}>&#x2715;</button>
        )}
        <button
          style={{ ...S.advancedToggle, ...(showAdvanced ? S.advancedToggleOn : {}) }}
          onClick={() => setShowAdvanced((v) => !v)}
          title={t.settings.showAdvancedTooltip}
        >
          {t.settings.showAdvanced}
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
                <span style={S.navLabel}>{navLabels[s.id] ?? s.label}</span>
              </button>
            );
          })}
        </nav>

        {/* Center content */}
        <div ref={contentRef} style={S.content}>

          {visibleIds.has("language") && (
            <div ref={(el) => { sectionRefs.current["language"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{t.settings.languageHeader}</div>
              <SettingRow label={t.settings.interfaceLanguage} desc={t.settings.interfaceLanguageDesc}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(locale === "en" ? S.btnActive : {}) }} onClick={() => setLocale("en")}>English</button>
                  <button style={{ ...S.btn, ...(locale === "zh-CN" ? S.btnActive : {}) }} onClick={() => setLocale("zh-CN")}>中文</button>
                </div>
              </SettingRow>
            </div>
          )}

          {visibleIds.has("appearance") && (
            <div ref={(el) => { sectionRefs.current["appearance"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{t.settings.appearanceHeader}</div>
              <SettingRow label={t.settings.fpsDisplayLabel} desc={t.settings.fpsDisplayDesc}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(fpsDisplay === "viewport" ? S.btnActive : {}) }} onClick={() => setFpsDisplay("viewport")}>{t.settings.fpsViewport}</button>
                  <button style={{ ...S.btn, ...(fpsDisplay === "none" ? S.btnActive : {}) }} onClick={() => setFpsDisplay("none")}>{t.settings.fpsNone}</button>
                </div>
              </SettingRow>
              <SettingRow label={t.settings.frameRateLimit} desc={t.settings.frameRateLimitDesc}>
                <div style={S.btnGroup}>
                  {[30, 60, 90, 120].map((fps) => (
                    <button key={fps} style={{ ...S.btn, ...(fpsLimit === fps ? S.btnActive : {}) }} onClick={() => setFpsLimit(fps)}>{fps}</button>
                  ))}
                </div>
              </SettingRow>
              <SettingRow label={t.settings.vsyncLabel} desc={t.settings.vsyncDesc}>
                <Toggle checked={prefs.vsyncEnabled} onChange={(v) => updatePref("vsyncEnabled", v)} />
              </SettingRow>
            </div>
          )}

          {visibleIds.has("console") && (
            <div ref={(el) => { sectionRefs.current["console"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{t.settings.consoleHeader}</div>
              <SettingRow label={t.settings.maxLogEntries} desc={t.settings.maxLogEntriesDesc}>
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
              <div style={S.sectionHeader}>{t.settings.layoutHeader}</div>
              <SettingRow label={t.settings.panelLayout} desc={t.settings.panelLayoutDesc}>
                <button style={S.actionBtn} onClick={handleResetLayout}>{t.settings.resetLayout}</button>
              </SettingRow>
            </div>
          )}

          {visibleIds.has("remote") && (
            <div ref={(el) => { sectionRefs.current["remote"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{t.settings.remoteHeader}</div>
              <SettingRow label={t.settings.connectionMode} desc={t.settings.connectionModeDesc}>
                <div style={S.btnGroup}>
                  <button style={{ ...S.btn, ...(connectMode === "local" ? S.btnActive : {}) }} onClick={() => connectMode !== "local" && handleConnect("local")} disabled={connecting}>{t.settings.localMode}</button>
                  <button style={{ ...S.btn, ...(connectMode === "remote" ? S.btnActive : {}) }} onClick={() => connectMode !== "remote" && handleConnect("remote")} disabled={connecting}>{t.settings.remoteMode}</button>
                </div>
              </SettingRow>
              {connecting && <div style={{ ...S.hint, color: "#89b4fa" }}>{t.settings.switching}</div>}
              {connectError && <div style={{ ...S.hint, color: "#f38ba8" }}>{connectError}</div>}
              <SettingRow label={t.settings.serverUrl}>
                <div style={{ display: "flex", gap: 6 }}>
                  <input type="text" value={remoteUrl} onChange={(e) => setRemoteUrl(e.target.value)} placeholder="ws://192.168.1.100:9100" style={S.textInput} />
                  <button style={S.actionBtn} onClick={handleTest} disabled={testStatus === "testing"}>
                    {testStatus === "testing" ? t.settings.testingBtn : t.settings.testBtn}
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
                  {t.settings.remoteInfo1}
                </p>
                <p style={S.infoParagraph}>
                  {t.settings.remoteInfo2}
                </p>
              </div>
            </div>
          )}

          {visibleIds.has("about") && (
            <div ref={(el) => { sectionRefs.current["about"] = el; }} style={S.section}>
              <div style={S.sectionHeader}>{t.settings.aboutHeader}</div>
              <div style={S.aboutGrid}>
                <AboutRow label="Guava Engine" value={engineVersion || "\u2014"} />
                <AboutRow label={t.settings.editorLabel} value="Electron" />
                <AboutRow label={t.settings.statusLabel} value={connected ? t.settings.statusConnected : t.settings.statusDisconnected} valueColor={connected ? "#a6e3a1" : "#f38ba8"} />
                {connectMode === "remote" && <AboutRow label={t.settings.addressLabel} value={remoteUrl} mono />}
              </div>
            </div>
          )}

          {visibleSections.length === 0 && (
            <div style={S.empty}>{t.settings.noMatch}</div>
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
    marginBottom: 10,
    paddingBottom: 6,
    borderBottom: "1px solid rgba(137,180,250,0.15)",
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
    padding: "8px 10px",
    minHeight: 36,
    background: "rgba(49,50,68,0.2)",
    borderRadius: 6,
    marginBottom: 4,
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
