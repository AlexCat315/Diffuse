import React, { useCallback, useEffect, useRef, useState } from "react";
import Editor, { type OnMount } from "@monaco-editor/react";
import type * as monaco from "monaco-editor";
import {
  IconLockClosed, IconLockOpen, IconFilledCircle,
  IconSave,
} from "../components/Icons";
import { Tooltip } from "../components/Tooltip";
import { rpc } from "../rpc";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";

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
  builtins: ["true", "false", "null", "undefined"],
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
      [/@symbols/, { cases: { "@operators": "operator", "@default": "" } }],
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

function monacoLanguage(lang: string): string {
  switch (lang) {
    case "zig": return "zig";
    case "csharp": return "csharp";
    case "lua": return "lua";
    default: return "plaintext";
  }
}

function langColor(lang: string): string {
  switch (lang) {
    case "zig": return "#f7a41d";
    case "csharp": return "#68217a";
    case "lua": return "#000080";
    default: return "#555";
  }
}

// ── Props ───────────────────────────────────────────────────────

interface ScriptEditorProps {
  path: string;
}

// ── Component ───────────────────────────────────────────────────

export function ScriptEditor({ path }: ScriptEditorProps) {
  const { t } = useI18n();
  const connected = useConnectionStore((s) => s.connected);

  const [content, setContent] = useState<string | null>(null);
  const [language, setLanguage] = useState("plaintext");
  const [readOnly, setReadOnly] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [cursorPos, setCursorPos] = useState({ line: 1, col: 1 });

  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const contentRef = useRef<string>("");

  // ── Load file content ──────────────────────────────────────

  useEffect(() => {
    if (!connected) return;
    let cancelled = false;
    rpc("script.getContent", { path }).then((res) => {
      if (cancelled) return;
      setContent(res.content);
      contentRef.current = res.content;
      setLanguage(res.language);
      setReadOnly(res.readOnly);
    }).catch(() => {
      if (!cancelled) setContent("");
    });
    return () => { cancelled = true; };
  }, [path, connected]);

  // ── Save ───────────────────────────────────────────────────

  const save = useCallback(async () => {
    if (readOnly) return;
    setSaving(true);
    try {
      const currentContent = editorRef.current?.getValue() ?? contentRef.current;
      await rpc("script.saveContent", { path, content: currentContent });
      contentRef.current = currentContent;
      setDirty(false);
    } catch {
      // ignore
    } finally {
      setSaving(false);
    }
  }, [path, readOnly]);

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

    editor.onDidChangeCursorPosition((e) => {
      setCursorPos({ line: e.position.lineNumber, col: e.position.column });
    });
  }, [save]);

  // ── Render ─────────────────────────────────────────────────

  if (!connected) {
    return <div style={styles.placeholder}>{t.app.connectingToEngine}</div>;
  }

  if (content === null) {
    return <div style={styles.placeholder}>Loading...</div>;
  }

  return (
    <div style={styles.root}>
      {/* Toolbar */}
      <div style={styles.toolbar}>
        <span style={styles.pathLabel}>{path}</span>
        <Tooltip label={readOnly ? t.scriptViewer.enableEdit : t.scriptViewer.disableEdit}>
          <button style={styles.iconBtn} onClick={() => setReadOnly((r) => !r)}>
            {readOnly
              ? <IconLockClosed size={13} color="#f38ba8" />
              : <IconLockOpen size={13} color="#a6e3a1" />
            }
          </button>
        </Tooltip>
        {!readOnly && (
          <Tooltip label={`${t.scriptViewer.save} (⌘S)`} shortcut="⌘S">
            <button
              style={{ ...styles.iconBtn, opacity: dirty ? 1 : 0.4 }}
              onClick={save}
              disabled={!dirty || saving}
            >
              <IconSave size={13} color={dirty ? "#89b4fa" : "#6c7086"} />
            </button>
          </Tooltip>
        )}
        {dirty && <IconFilledCircle size={6} color="#f9e2af" />}
      </div>

      {/* Editor */}
      <div style={styles.editorWrapper}>
        <Editor
          height="100%"
          language={monacoLanguage(language)}
          value={content}
          theme="vs-dark"
          onMount={handleEditorMount}
          onChange={(value) => {
            if (value !== undefined) {
              contentRef.current = value;
              setDirty(value !== content);
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
            smoothScrolling: true,
            cursorSmoothCaretAnimation: "on",
            padding: { top: 8 },
            find: { addExtraSpaceOnTop: false },
          }}
        />
      </div>

      {/* Status bar */}
      <div style={styles.statusBar}>
        <span>Ln {cursorPos.line}, Col {cursorPos.col}</span>
        <span style={styles.statusSep}>|</span>
        <span style={{
          background: langColor(language),
          padding: "0 5px",
          borderRadius: 2,
          color: "#fff",
          fontWeight: 600,
          fontSize: 9,
        }}>
          {language}
        </span>
        <span style={styles.statusSep}>|</span>
        <span>UTF-8</span>
        <div style={{ flex: 1 }} />
        {readOnly && (
          <span style={{ color: "#f38ba8" }}>
            <IconLockClosed size={10} color="#f38ba8" /> Read-only
          </span>
        )}
        {dirty && (
          <span style={{ color: "#f9e2af" }}>Modified</span>
        )}
      </div>
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  root: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    background: "#1e1e2e",
  },
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
    gap: 4,
    padding: "2px 8px",
    background: "#181825",
    borderBottom: "1px solid #252537",
    minHeight: 24,
  },
  pathLabel: {
    fontSize: 10,
    color: "#585b70",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    flex: 1,
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
  editorWrapper: {
    flex: 1,
    position: "relative",
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
