import React, { useCallback, useEffect, useRef } from "react";
import { useLocalState } from "../store/local-state";
import Editor, { type OnMount } from "@monaco-editor/react";
import type * as monaco from "monaco-editor";

import { rpc } from "../rpc";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";
import type { ScriptFileInfo } from "../../shared/rpc-types";

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
  const [selectedPath, setSelectedPath] = useLocalState<string | null>(null);
  const [content, setContent] = useLocalState<string>("");
  const [language, setLanguage] = useLocalState<string>("zig");
  const [readOnly, setReadOnly] = useSyncedState("script-viewer", "readOnly", false);
  const [dirty, setDirty] = useLocalState(false);
  const [saving, setSaving] = useLocalState(false);
  const [searchQuery, setSearchQuery] = useLocalState("");

  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);

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

  // ── Open a script file ─────────────────────────────────────

  const openScript = useCallback(async (path: string) => {
    try {
      const res = await rpc("script.getContent", { path });
      setContent(res.content);
      setLanguage(res.language);
      setReadOnly(res.readOnly);
      setSelectedPath(path);
      setDirty(false);
    } catch {
      // ignore
    }
  }, []);

  // ── Save ───────────────────────────────────────────────────

  const save = useCallback(async () => {
    if (!selectedPath || readOnly) return;
    setSaving(true);
    try {
      const currentContent = editorRef.current?.getValue() ?? content;
      await rpc("script.saveContent", { path: selectedPath, content: currentContent });
      setDirty(false);
    } catch {
      // ignore
    } finally {
      setSaving(false);
    }
  }, [selectedPath, readOnly, content]);

  // ── Keyboard shortcut ──────────────────────────────────────

  const handleEditorMount: OnMount = useCallback((editor, monacoInstance) => {
    editorRef.current = editor;
    registerZigLanguage(monacoInstance);

    // Ctrl/Cmd+S to save
    editor.addAction({
      id: "guava-save-script",
      label: "Save Script",
      keybindings: [monacoInstance.KeyMod.CtrlCmd | monacoInstance.KeyCode.KeyS],
      run: () => { save(); },
    });
  }, [save]);

  // ── Filter scripts ─────────────────────────────────────────

  const filteredScripts = searchQuery
    ? scripts.filter((s) =>
        s.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
        s.path.toLowerCase().includes(searchQuery.toLowerCase()),
      )
    : scripts;

  // ── Early returns ──────────────────────────────────────────

  if (!connected) {
    return <div style={styles.placeholder}>{t.app.connectingToEngine}</div>;
  }

  // ── Render ─────────────────────────────────────────────────

  return (
    <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column" }}>
      {/* Toolbar */}
      <div style={styles.toolbar}>
        <span style={styles.toolbarTitle}>{t.scriptViewer.title}</span>
        {selectedPath && (
          <>
            <span style={{ fontSize: 11, color: "#a6adc8", flex: 1 }}>
              {selectedPath}
              {dirty && <span style={{ color: "#f9e2af" }}> ●</span>}
            </span>
            <button
              style={styles.toolbarBtn}
              onClick={() => setReadOnly(!readOnly)}
              title={readOnly ? t.scriptViewer.enableEdit : t.scriptViewer.disableEdit}
            >
              {readOnly ? "🔒" : "✏️"}
            </button>
            {!readOnly && (
              <button
                style={{
                  ...styles.toolbarBtn,
                  opacity: dirty ? 1 : 0.5,
                }}
                onClick={save}
                disabled={!dirty || saving}
              >
                {saving ? "..." : t.scriptViewer.save}
              </button>
            )}
          </>
        )}
      </div>

      <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
        {/* File list sidebar */}
        <div style={styles.sidebar}>
          <input
            style={styles.searchInput}
            placeholder={t.scriptViewer.search}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
          <div style={styles.fileList}>
            {filteredScripts.length === 0 && (
              <div style={styles.emptyHint}>{t.scriptViewer.noScripts}</div>
            )}
            {filteredScripts.map((s) => (
              <div
                key={s.path}
                style={{
                  ...styles.fileItem,
                  background: s.path === selectedPath ? "#313244" : "transparent",
                }}
                onClick={() => openScript(s.path)}
              >
                <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                  <span style={{
                    fontSize: 9,
                    padding: "1px 4px",
                    borderRadius: 3,
                    background: langColor(s.language),
                    color: "#fff",
                    fontWeight: 600,
                  }}>
                    {s.language}
                  </span>
                  <span style={{ color: "#cdd6f4", fontSize: 11 }}>{s.name}</span>
                </div>
                <div style={{ fontSize: 9, color: "#585b70", marginTop: 1 }}>
                  {s.path}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Editor area */}
        <div style={{ flex: 1, position: "relative" }}>
          {selectedPath ? (
            <Editor
              height="100%"
              language={monacoLanguage(language)}
              value={content}
              theme="vs-dark"
              onMount={handleEditorMount}
              onChange={(value) => {
                if (value !== undefined) {
                  setContent(value);
                  setDirty(true);
                }
              }}
              options={{
                readOnly,
                fontSize: 13,
                lineNumbers: "on",
                renderLineHighlight: "all",
                minimap: { enabled: true },
                scrollBeyondLastLine: false,
                wordWrap: "off",
                tabSize: 4,
                insertSpaces: true,
                automaticLayout: true,
                find: {
                  addExtraSpaceOnTop: false,
                },
              }}
            />
          ) : (
            <div style={styles.placeholder}>
              {t.scriptViewer.selectFile}
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
  sidebar: {
    width: 220,
    borderRight: "1px solid #313244",
    background: "#181825",
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
  },
  searchInput: {
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "none",
    borderBottom: "1px solid #313244",
    padding: "6px 10px",
    fontSize: 11,
    outline: "none",
  },
  fileList: {
    flex: 1,
    overflowY: "auto",
    padding: 4,
  },
  fileItem: {
    padding: "4px 8px",
    cursor: "pointer",
    borderRadius: 4,
    marginBottom: 1,
  },
  emptyHint: {
    color: "#585b70",
    fontStyle: "italic",
    fontSize: 11,
    padding: 8,
    textAlign: "center",
  },
};
