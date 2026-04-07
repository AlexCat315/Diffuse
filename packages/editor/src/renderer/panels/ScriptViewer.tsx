import React, { useCallback, useEffect, useRef, useState } from "react";
import { useLocalState } from "../store/local-state";
import Editor, { type OnMount } from "@monaco-editor/react";
import type * as monaco from "monaco-editor";
import {
  IconLockClosed, IconLockOpen, IconFilledCircle, IconScript, IconClose,
  IconSave, IconRefresh,
} from "../components/Icons";
import { Tooltip } from "../components/Tooltip";

import { rpc } from "../rpc";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";
import type { ScriptFileInfo } from "../../shared/rpc-types";

// ── Tab type ────────────────────────────────────────────────────

interface ScriptTab {
  path: string;
  name: string;
  language: string;
  content: string;
  dirty: boolean;
  readOnly: boolean;
}

// ── Zig language definition for Monaco ──────────────────────────

const ZIG_MONARCH: monaco.languages.IMonarchLanguage = {
  keywords: [
    "addrspace", "align", "allowzero", "and", "anyframe", "anytype",
    "asm", "async", "await", "break", "callconv", "catch", "comptime",
    "const", "continue", "defer", "else", "enum", "errdefer", "error",
    "export", "extern", "fn", "for", "if", "inline", "linksection",
    "noalias", "nosuspend", "opaque", "or", "orelse", "packed",
    "pub", "resume", "return", "struct", "suspend", "switch", "test",
    "threadlocal", "try", "union", "unreachable", "usingnamespace",
    "var", "volatile", "while",
  ],
  builtins: [
    "true", "false", "null", "undefined",
  ],
  typeKeywords: [
    "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128",
    "isize", "usize", "f16", "f32", "f64", "f80", "f128",
    "bool", "void", "noreturn", "type", "anyerror", "comptime_int", "comptime_float",
  ],
  operators: [
    "+", "-", "*", "/", "%", "++", "+%", "-%", "*%", "/%",
    "==", "!=", "<", ">", "<=", ">=",
    "&", "|", "^", "~", "<<", ">>",
    "=", "+=", "-=", "*=", "/=", "%=",
    "||", "&&", "!", "=>", "->",
  ],
  symbols: /[=><!~?:&|+\-*/^%]+/,
  escapes: /\\(?:[abefnrtv\\"']|x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]+\})/,

  tokenizer: {
    root: [
      [/[a-zA-Z_]\w*/, {
        cases: {
          "@keywords": "keyword",
          "@builtins": "constant",
          "@typeKeywords": "type",
          "@default": "identifier",
        },
      }],
      [/@"[^"]*"/, "identifier"],
      [/@\w+/, "annotation"],
      { include: "@whitespace" },
      [/[{}()[\]]/, "@brackets"],
      [/@symbols/, {
        cases: {
          "@operators": "operator",
          "@default": "",
        },
      }],
      [/0[xX][0-9a-fA-F_]+/, "number.hex"],
      [/0[oO][0-7_]+/, "number.octal"],
      [/0[bB][01_]+/, "number.binary"],
      [/\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?\d+)?/, "number"],
      [/"/, "string", "@string"],
      [/'(?:\\.|[^'\\])'/, "string.char"],
    ],
    whitespace: [
      [/\s+/, "white"],
      [/\/\/!.*$/, "comment.doc"],
      [/\/\/.*$/, "comment"],
    ],
    string: [
      [/[^\\"]+/, "string"],
      [/@escapes/, "string.escape"],
      [/\\./, "string.escape.invalid"],
      [/"/, "string", "@pop"],
    ],
  },
};

function registerZigLanguage(monacoInstance: typeof monaco) {
  if (!monacoInstance.languages.getLanguages().some((l) => l.id === "zig")) {
    monacoInstance.languages.register({ id: "zig", extensions: [".zig"] });
    monacoInstance.languages.setMonarchTokensProvider("zig", ZIG_MONARCH);
  }
}

// ── Language mapping ────────────────────────────────────────────

function monacoLanguage(lang: string): string {
  switch (lang) {
    case "zig": return "zig";
    case "csharp": return "csharp";
    case "lua": return "lua";
    default: return "plaintext";
  }
}

// ── Main component ──────────────────────────────────────────────

export function ScriptViewer() {
  const { t } = useI18n();
  const connected = useConnectionStore((s) => s.connected);

  const [scripts, setScripts] = useLocalState<ScriptFileInfo[]>([]);
  const [tabs, setTabs] = useLocalState<ScriptTab[]>([]);
  const [activeTabPath, setActiveTabPath] = useLocalState<string | null>(null);
  const [saving, setSaving] = useLocalState(false);
  const [searchQuery, setSearchQuery] = useLocalState("");
  const [cursorPos, setCursorPos] = useState({ line: 1, col: 1 });
  const [sidebarWidth, setSidebarWidth] = useLocalState(200);

  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const resizeRef = useRef<{ startX: number; startW: number } | null>(null);

  const activeTab = tabs.find((tab) => tab.path === activeTabPath) ?? null;

  // ── Fetch script list ──────────────────────────────────────

  const fetchScripts = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await rpc("script.listScripts", {});
      setScripts(res.scripts);
    } catch {
      setScripts([]);
    }
  }, [connected]);

  useEffect(() => {
    fetchScripts();
  }, [fetchScripts]);

  // ── Open a script file as a tab ────────────────────────────

  const openScript = useCallback(async (path: string) => {
    // If already open, just switch to it
    const existing = tabs.find((tab) => tab.path === path);
    if (existing) {
      setActiveTabPath(path);
      return;
    }
    try {
      const res = await rpc("script.getContent", { path });
      const info = scripts.find((s) => s.path === path);
      const newTab: ScriptTab = {
        path,
        name: info?.name ?? path.split("/").pop() ?? path,
        language: res.language,
        content: res.content,
        dirty: false,
        readOnly: res.readOnly,
      };
      setTabs((prev) => [...prev, newTab]);
      setActiveTabPath(path);
    } catch {
      // ignore
    }
  }, [tabs, scripts]);

  // ── Close tab ──────────────────────────────────────────────

  const closeTab = useCallback((path: string, e?: React.MouseEvent) => {
    e?.stopPropagation();
    setTabs((prev) => {
      const next = prev.filter((tab) => tab.path !== path);
      if (activeTabPath === path) {
        const idx = prev.findIndex((tab) => tab.path === path);
        const newActive = next[Math.min(idx, next.length - 1)]?.path ?? null;
        setActiveTabPath(newActive);
      }
      return next;
    });
  }, [activeTabPath]);

  // ── Update tab content ─────────────────────────────────────

  const updateTabContent = useCallback((path: string, content: string) => {
    setTabs((prev) =>
      prev.map((tab) =>
        tab.path === path ? { ...tab, content, dirty: true } : tab,
      ),
    );
  }, []);

  // ── Toggle read-only ───────────────────────────────────────

  const toggleReadOnly = useCallback(() => {
    if (!activeTab) return;
    setTabs((prev) =>
      prev.map((tab) =>
        tab.path === activeTab.path ? { ...tab, readOnly: !tab.readOnly } : tab,
      ),
    );
  }, [activeTab]);

  // ── Save ───────────────────────────────────────────────────

  const save = useCallback(async () => {
    if (!activeTab || activeTab.readOnly) return;
    setSaving(true);
    try {
      const currentContent = editorRef.current?.getValue() ?? activeTab.content;
      await rpc("script.saveContent", { path: activeTab.path, content: currentContent });
      setTabs((prev) =>
        prev.map((tab) =>
          tab.path === activeTab.path ? { ...tab, dirty: false, content: currentContent } : tab,
        ),
      );
    } catch {
      // ignore
    } finally {
      setSaving(false);
    }
  }, [activeTab]);

  // ── Editor mount ───────────────────────────────────────────

  const handleEditorMount: OnMount = useCallback((editor, monacoInstance) => {
    editorRef.current = editor;
    registerZigLanguage(monacoInstance);

    editor.addAction({
      id: "guava-save-script",
      label: "Save Script",
      keybindings: [monacoInstance.KeyMod.CtrlCmd | monacoInstance.KeyCode.KeyS],
      run: () => { save(); },
    });

    // Track cursor position
    editor.onDidChangeCursorPosition((e) => {
      setCursorPos({ line: e.position.lineNumber, col: e.position.column });
    });
  }, [save]);

  // ── Sidebar resize ─────────────────────────────────────────

  const handleResizeStart = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    resizeRef.current = { startX: e.clientX, startW: sidebarWidth };
    const handleMove = (ev: MouseEvent) => {
      if (!resizeRef.current) return;
      const delta = ev.clientX - resizeRef.current.startX;
      const newW = Math.max(120, Math.min(400, resizeRef.current.startW + delta));
      setSidebarWidth(newW);
    };
    const handleUp = () => {
      resizeRef.current = null;
      document.removeEventListener("mousemove", handleMove);
      document.removeEventListener("mouseup", handleUp);
    };
    document.addEventListener("mousemove", handleMove);
    document.addEventListener("mouseup", handleUp);
  }, [sidebarWidth]);

  // ── Filter scripts ─────────────────────────────────────────

  const filteredScripts = searchQuery
    ? scripts.filter((s) =>
        s.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
        s.path.toLowerCase().includes(searchQuery.toLowerCase()),
      )
    : scripts;

  // ── Format file size ───────────────────────────────────────

  const formatSize = (bytes: number) => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  // ── Early returns ──────────────────────────────────────────

  if (!connected) {
    return <div style={styles.placeholder}>{t.app.connectingToEngine}</div>;
  }

  // ── Render ─────────────────────────────────────────────────

  return (
    <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column", background: "#1e1e2e" }}>
      {/* Top toolbar */}
      <div style={styles.toolbar}>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <IconScript size={14} color="#cba6f7" />
          <span style={styles.toolbarTitle}>{t.scriptViewer.title}</span>
          <span style={{ fontSize: 10, color: "#585b70", fontWeight: 400 }}>
            {scripts.length > 0 && `(${scripts.length})`}
          </span>
        </div>
        <div style={{ flex: 1 }} />
        <Tooltip label={t.scriptViewer.refreshScripts ?? "Refresh"}>
          <button style={styles.iconBtn} onClick={fetchScripts}>
            <IconRefresh size={13} color="#6c7086" />
          </button>
        </Tooltip>
      </div>

      <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
        {/* File list sidebar */}
        <div style={{ ...styles.sidebar, width: sidebarWidth }}>
          <div style={styles.searchContainer}>
            <input
              style={styles.searchInput}
              placeholder={t.scriptViewer.search}
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
            />
          </div>
          <div style={styles.fileList}>
            {filteredScripts.length === 0 && (
              <div style={styles.emptyHint}>{t.scriptViewer.noScripts}</div>
            )}
            {filteredScripts.map((s) => {
              const isActive = s.path === activeTabPath;
              const isOpen = tabs.some((tab) => tab.path === s.path);
              return (
                <div
                  key={s.path}
                  style={{
                    ...styles.fileItem,
                    background: isActive ? "rgba(137,180,250,0.12)" : "transparent",
                    borderLeft: isActive ? "2px solid #89b4fa" : "2px solid transparent",
                  }}
                  onClick={() => openScript(s.path)}
                  title={s.path}
                >
                  <div style={{ display: "flex", alignItems: "center", gap: 6, minWidth: 0 }}>
                    <div style={{
                      width: 6, height: 6, borderRadius: "50%",
                      background: langColor(s.language),
                      flexShrink: 0,
                    }} />
                    <span style={{
                      color: isActive ? "#cdd6f4" : "#a6adc8",
                      fontSize: 11,
                      fontWeight: isActive ? 500 : 400,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    }}>
                      {s.name}
                    </span>
                    {isOpen && (
                      <span style={{ fontSize: 8, color: "#89b4fa", flexShrink: 0 }}>●</span>
                    )}
                  </div>
                  <div style={{
                    fontSize: 9, color: "#45475a", marginTop: 1,
                    overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                  }}>
                    {formatSize(s.sizeBytes)}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* Sidebar resize handle */}
        <div
          style={styles.resizeHandle}
          onMouseDown={handleResizeStart}
        />

        {/* Editor area */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
          {/* Tab bar */}
          {tabs.length > 0 && (
            <div style={styles.tabBar}>
              {tabs.map((tab) => {
                const isActive = tab.path === activeTabPath;
                return (
                  <div
                    key={tab.path}
                    style={{
                      ...styles.tab,
                      background: isActive ? "#1e1e2e" : "transparent",
                      borderBottom: isActive ? "2px solid #89b4fa" : "2px solid transparent",
                      color: isActive ? "#cdd6f4" : "#6c7086",
                    }}
                    onClick={() => setActiveTabPath(tab.path)}
                  >
                    <div style={{
                      width: 6, height: 6, borderRadius: "50%",
                      background: langColor(tab.language),
                      flexShrink: 0,
                    }} />
                    <span style={{
                      overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                    }}>
                      {tab.name}
                    </span>
                    {tab.dirty && <IconFilledCircle size={6} color="#f9e2af" />}
                    <button
                      style={styles.tabCloseBtn}
                      onClick={(e) => closeTab(tab.path, e)}
                      title="Close"
                    >
                      <IconClose size={10} color={isActive ? "#6c7086" : "#45475a"} />
                    </button>
                  </div>
                );
              })}
            </div>
          )}

          {/* Active tab toolbar */}
          {activeTab && (
            <div style={styles.editorToolbar}>
              <span style={{
                fontSize: 10, color: "#585b70",
                overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                flex: 1,
              }}>
                {activeTab.path}
              </span>
              <Tooltip label={activeTab.readOnly ? t.scriptViewer.enableEdit : t.scriptViewer.disableEdit}>
                <button style={styles.iconBtn} onClick={toggleReadOnly}>
                  {activeTab.readOnly
                    ? <IconLockClosed size={13} color="#f38ba8" />
                    : <IconLockOpen size={13} color="#a6e3a1" />
                  }
                </button>
              </Tooltip>
              {!activeTab.readOnly && (
                <Tooltip label={`${t.scriptViewer.save} (⌘S)`} shortcut="⌘S">
                  <button
                    style={{
                      ...styles.iconBtn,
                      opacity: activeTab.dirty ? 1 : 0.4,
                    }}
                    onClick={save}
                    disabled={!activeTab.dirty || saving}
                  >
                    <IconSave size={13} color={activeTab.dirty ? "#89b4fa" : "#6c7086"} />
                  </button>
                </Tooltip>
              )}
            </div>
          )}

          {/* Editor */}
          <div style={{ flex: 1, position: "relative" }}>
            {activeTab ? (
              <Editor
                height="100%"
                language={monacoLanguage(activeTab.language)}
                value={activeTab.content}
                theme="vs-dark"
                onMount={handleEditorMount}
                onChange={(value) => {
                  if (value !== undefined && activeTab) {
                    updateTabContent(activeTab.path, value);
                  }
                }}
                options={{
                  readOnly: activeTab.readOnly,
                  fontSize: 13,
                  lineNumbers: "on",
                  renderLineHighlight: "all",
                  minimap: { enabled: true },
                  scrollBeyondLastLine: false,
                  wordWrap: "off",
                  tabSize: 4,
                  insertSpaces: true,
                  automaticLayout: true,
                  smoothScrolling: true,
                  cursorSmoothCaretAnimation: "on",
                  padding: { top: 8 },
                  find: { addExtraSpaceOnTop: false },
                }}
              />
            ) : (
              <div style={styles.emptyState}>
                <IconScript size={40} color="#313244" />
                <span style={{ fontSize: 13, color: "#585b70", marginTop: 12 }}>
                  {t.scriptViewer.selectFile}
                </span>
                <span style={{ fontSize: 11, color: "#45475a", marginTop: 4 }}>
                  {t.scriptViewer.openFromSidebar ?? "Open a file from the sidebar to start editing."}
                </span>
              </div>
            )}
          </div>

          {/* Status bar */}
          {activeTab && (
            <div style={styles.statusBar}>
              <span>Ln {cursorPos.line}, Col {cursorPos.col}</span>
              <span style={styles.statusSep}>|</span>
              <span style={{
                background: langColor(activeTab.language),
                padding: "0 5px",
                borderRadius: 2,
                color: "#fff",
                fontWeight: 600,
                fontSize: 9,
              }}>
                {activeTab.language}
              </span>
              <span style={styles.statusSep}>|</span>
              <span>UTF-8</span>
              <div style={{ flex: 1 }} />
              {activeTab.readOnly && (
                <span style={{ color: "#f38ba8" }}>
                  <IconLockClosed size={10} color="#f38ba8" /> Read-only
                </span>
              )}
              {activeTab.dirty && (
                <span style={{ color: "#f9e2af" }}>Modified</span>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Helpers ─────────────────────────────────────────────────────

function langColor(lang: string): string {
  switch (lang) {
    case "zig": return "#f7a41d";
    case "csharp": return "#68217a";
    case "lua": return "#000080";
    default: return "#555";
  }
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  placeholder: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    color: "#6c7086",
    fontSize: 13,
  },
  emptyState: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    gap: 0,
  },
  toolbar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "5px 10px",
    borderBottom: "1px solid #313244",
    background: "#181825",
    minHeight: 30,
  },
  toolbarTitle: {
    fontWeight: 600,
    fontSize: 12,
    color: "#cdd6f4",
  },
  iconBtn: {
    background: "none",
    border: "none",
    padding: 4,
    cursor: "pointer",
    borderRadius: 4,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  sidebar: {
    borderRight: "none",
    background: "#181825",
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
    flexShrink: 0,
  },
  searchContainer: {
    padding: "6px 8px",
    borderBottom: "1px solid #313244",
  },
  searchInput: {
    width: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "1px solid #313244",
    borderRadius: 4,
    padding: "4px 8px",
    fontSize: 11,
    outline: "none",
    boxSizing: "border-box",
  },
  fileList: {
    flex: 1,
    overflowY: "auto",
    padding: "4px 0",
  },
  fileItem: {
    padding: "5px 10px",
    cursor: "pointer",
    marginBottom: 0,
    transition: "background 0.1s",
  },
  emptyHint: {
    color: "#585b70",
    fontStyle: "italic",
    fontSize: 11,
    padding: 16,
    textAlign: "center",
  },
  resizeHandle: {
    width: 3,
    cursor: "col-resize",
    background: "#313244",
    flexShrink: 0,
    transition: "background 0.15s",
  },
  tabBar: {
    display: "flex",
    alignItems: "stretch",
    background: "#181825",
    borderBottom: "1px solid #313244",
    overflow: "hidden",
    minHeight: 30,
  },
  tab: {
    display: "flex",
    alignItems: "center",
    gap: 5,
    padding: "0 10px",
    fontSize: 11,
    cursor: "pointer",
    whiteSpace: "nowrap",
    minWidth: 0,
    maxWidth: 160,
    borderRight: "1px solid #313244",
    userSelect: "none",
  },
  tabCloseBtn: {
    background: "none",
    border: "none",
    padding: 2,
    cursor: "pointer",
    display: "flex",
    alignItems: "center",
    borderRadius: 3,
    marginLeft: 2,
    flexShrink: 0,
  },
  editorToolbar: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "2px 8px",
    background: "#181825",
    borderBottom: "1px solid #252537",
    minHeight: 24,
  },
  statusBar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "2px 10px",
    background: "#181825",
    borderTop: "1px solid #313244",
    fontSize: 10,
    color: "#585b70",
    minHeight: 20,
    userSelect: "none",
  },
  statusSep: {
    color: "#313244",
  },
};
