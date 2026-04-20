import React, { useCallback, useMemo } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n } from "../i18n";
import { IconSettings, IconTranslate, IconModel, IconClose, IconKeyboard } from "../components/Icons";
import {
  GIZMO_SHORTCUT_DEFS,
  MESH_SHORTCUT_DEFS,
  EDITOR_FIXED_SHORTCUTS,
  loadGizmoShortcuts,
  saveGizmoShortcuts,
  loadMeshShortcuts,
  saveMeshShortcuts,
  formatBinding,
  type ShortcutBinding,
} from "../store/shortcut-config";

// ── Category definitions ───────────────────────────────────────

interface CategoryDef {
  id: string;
  icon: React.ReactNode;
}

const CATEGORIES: CategoryDef[] = [
  { id: "editor", icon: <IconSettings size={12} /> },
  { id: "gizmo",  icon: <IconTranslate size={12} /> },
  { id: "mesh",   icon: <IconModel size={12} /> },
];

// ── Main component ───────────────────────────────────────────────

export function KeybindingsPanel() {
  const { t } = useI18n();

  const categoryLabels: Record<string, string> = {
    editor: t.keybindings.categoryEditor,
    gizmo:  t.keybindings.categoryGizmo,
    mesh:   t.keybindings.categoryMesh,
  };
  const gizmoLabels = t.shortcuts.gizmo as Record<string, string>;
  const meshLabels  = t.shortcuts.mesh  as Record<string, string>;
  const editorLabels = t.shortcuts.editor as Record<string, string>;

  const [activeCategory, setActiveCategory] = useLocalState<string>("editor");
  const [search, setSearch] = useLocalState("");
  const [recording, setRecording] = useLocalState<string | null>(null);
  const [gizmoShortcuts, setGizmoShortcuts] = useLocalState<Record<string, ShortcutBinding>>(loadGizmoShortcuts);
  const [meshShortcuts, setMeshShortcuts] = useLocalState<Record<string, ShortcutBinding>>(loadMeshShortcuts);

  const q = search.toLowerCase().trim();

  // ── Gizmo shortcut update ───────────────────────────────────────
  const updateGizmo = useCallback((id: string, binding: ShortcutBinding) => {
    setGizmoShortcuts((prev) => {
      const next = { ...prev, [id]: binding };
      saveGizmoShortcuts(next);
      return next;
    });
  }, []);

  const resetGizmo = useCallback(() => {
    const defaults: Record<string, ShortcutBinding> = {};
    for (const s of GIZMO_SHORTCUT_DEFS) defaults[s.id] = { ...s.default };
    setGizmoShortcuts(defaults);
    saveGizmoShortcuts(defaults);
  }, []);

  // ── Mesh shortcut update ────────────────────────────────────────
  const updateMesh = useCallback((id: string, binding: ShortcutBinding) => {
    setMeshShortcuts((prev) => {
      const next = { ...prev, [id]: binding };
      saveMeshShortcuts(next);
      return next;
    });
  }, []);

  const resetMesh = useCallback(() => {
    const defaults: Record<string, ShortcutBinding> = {};
    for (const s of MESH_SHORTCUT_DEFS) defaults[s.id] = { ...s.default };
    setMeshShortcuts(defaults);
    saveMeshShortcuts(defaults);
  }, []);

  // ── Key recording ───────────────────────────────────────────────
  const handleKeyRecord = useCallback((e: React.KeyboardEvent) => {
    if (!recording) return;
    e.preventDefault();
    e.stopPropagation();
    const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (["Control", "Shift", "Alt", "Meta"].includes(key)) return;
    const binding: ShortcutBinding = {
      key,
      ctrl: e.ctrlKey || e.metaKey,
      shift: e.shiftKey,
      alt: e.altKey,
    };
    if (recording.startsWith("gizmo:")) {
      updateGizmo(recording.slice(6), binding);
    } else if (recording.startsWith("mesh:")) {
      updateMesh(recording.slice(5), binding);
    }
    setRecording(null);
  }, [recording, updateGizmo, updateMesh]);

  // ── Filtered categories based on search ────────────────────────
  const visibleCategories = useMemo(() => {
    if (!q) return CATEGORIES;
    return CATEGORIES.filter((c) => {
      if (categoryLabels[c.id]?.toLowerCase().includes(q)) return true;
      if (c.id === "editor") {
        return EDITOR_FIXED_SHORTCUTS.some(
          (s) => (editorLabels[s.id] ?? s.id).toLowerCase().includes(q) || s.display.toLowerCase().includes(q),
        );
      }
      if (c.id === "gizmo") {
        return GIZMO_SHORTCUT_DEFS.some(
          (s) => (gizmoLabels[s.id] ?? s.id).toLowerCase().includes(q),
        );
      }
      if (c.id === "mesh") {
        return MESH_SHORTCUT_DEFS.some(
          (s) => (meshLabels[s.id] ?? s.id).toLowerCase().includes(q),
        );
      }
      return false;
    });
  }, [q]);

  return (
    <div style={S.root} onKeyDown={handleKeyRecord} tabIndex={0}>
      {/* Search bar */}
      <div style={S.searchBar}>
        <span style={S.searchIcon}>&#x2315;</span>
        <input
          style={S.searchInput}
          placeholder={t.keybindings.searchPlaceholder}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {search && (
          <button style={S.searchClear} onClick={() => setSearch("")}>&#x2715;</button>
        )}
      </div>

      <div style={S.body}>
        {/* Left nav */}
        <nav style={S.nav}>
          {CATEGORIES.map((c) => {
            const visible = visibleCategories.some((v) => v.id === c.id);
            if (!visible && q) return null;
            return (
              <button
                key={c.id}
                style={{
                  ...S.navItem,
                  ...(activeCategory === c.id ? S.navItemActive : {}),
                  ...(visible ? {} : { opacity: 0.3 }),
                }}
                onClick={() => setActiveCategory(c.id)}
              >
                <span style={S.navIcon}>{c.icon}</span>
                <span style={S.navLabel}>{categoryLabels[c.id] ?? c.id}</span>
              </button>
            );
          })}
        </nav>

        {/* Content */}
        <div style={S.content}>

          {/* Editor (fixed) */}
          {activeCategory === "editor" && (
            <div>
              <div style={S.sectionHeader}>{t.keybindings.editorTitle}</div>
              <p style={S.sectionDesc}>
                {t.keybindings.editorDesc}
              </p>
              <div style={S.table}>
                <div style={S.headerRow}>
                  <span style={S.colAction}>{t.keybindings.colAction}</span>
                  <span style={S.colKey}>{t.keybindings.colShortcut}</span>
                  <span style={S.colFixed}>{t.keybindings.colStatus}</span>
                </div>
                {EDITOR_FIXED_SHORTCUTS
                  .filter((s) => !q || (editorLabels[s.id] ?? s.id).toLowerCase().includes(q) || s.display.toLowerCase().includes(q))
                  .map((s) => (
                    <div key={s.id} style={S.row}>
                      <span style={S.colAction}>{editorLabels[s.id] ?? s.id}</span>
                      <span style={S.colKey}><code style={S.keyCode}>{s.display}</code></span>
                      <span style={{ ...S.colFixed, ...S.fixedBadge }}>{t.keybindings.fixedBadge}</span>
                    </div>
                  ))}
              </div>
            </div>
          )}

          {/* Gizmo shortcuts */}
          {activeCategory === "gizmo" && (
            <div>
              <div style={S.sectionHeader}>{t.keybindings.gizmoTitle}</div>
              <p style={S.sectionDesc}>
                {t.keybindings.gizmoDesc}
              </p>
              <div style={S.table}>
                <div style={S.headerRow}>
                  <span style={S.colAction}>{t.keybindings.colAction}</span>
                  <span style={S.colKey}>{t.keybindings.colShortcut}</span>
                  <span style={S.colRecord} />
                </div>
                {GIZMO_SHORTCUT_DEFS
                  .filter((s) => !q || (gizmoLabels[s.id] ?? s.id).toLowerCase().includes(q))
                  .map((def) => {
                    const binding = gizmoShortcuts[def.id] || def.default;
                    const recId = `gizmo:${def.id}`;
                    const isRec = recording === recId;
                    return (
                      <div key={def.id} style={{ ...S.row, ...(isRec ? S.rowRecording : {}) }}>
                        <span style={S.colAction}>{gizmoLabels[def.id] ?? def.id}</span>
                        <span style={S.colKey}>
                          {isRec
                            ? <span style={S.recordingBadge}>{t.keybindings.pressNewKey}</span>
                            : <code style={S.keyCode}>{formatBinding(binding)}</code>}
                        </span>
                        <span style={S.colRecord}>
                          <button style={S.recordBtn} onClick={() => setRecording(isRec ? null : recId)} title={t.keybindings.recordBtn}>
                            {isRec ? <IconClose size={10} /> : <IconKeyboard size={12} />}
                          </button>
                        </span>
                      </div>
                    );
                  })}
              </div>
              <div style={S.footer}>
                <button style={S.resetBtn} onClick={resetGizmo}>{t.keybindings.resetToDefaults}</button>
                <span style={S.hint}>{t.keybindings.savedLocallyInstant}</span>
              </div>
            </div>
          )}

          {/* Mesh edit shortcuts */}
          {activeCategory === "mesh" && (
            <div>
              <div style={S.sectionHeader}>{t.keybindings.meshTitle}</div>
              <p style={S.sectionDesc}>
                {t.keybindings.meshDesc}
              </p>
              <div style={S.table}>
                <div style={S.headerRow}>
                  <span style={S.colAction}>{t.keybindings.colAction}</span>
                  <span style={S.colKey}>{t.keybindings.colShortcut}</span>
                  <span style={S.colRecord} />
                </div>
                {MESH_SHORTCUT_DEFS
                  .filter((s) => !q || (meshLabels[s.id] ?? s.id).toLowerCase().includes(q))
                  .map((def) => {
                    const binding = meshShortcuts[def.id] || def.default;
                    const recId = `mesh:${def.id}`;
                    const isRec = recording === recId;
                    return (
                      <div key={def.id} style={{ ...S.row, ...(isRec ? S.rowRecording : {}) }}>
                        <span style={S.colAction}>{meshLabels[def.id] ?? def.id}</span>
                        <span style={S.colKey}>
                          {isRec
                            ? <span style={S.recordingBadge}>{t.keybindings.pressNewKey}</span>
                            : <code style={S.keyCode}>{formatBinding(binding)}</code>}
                        </span>
                        <span style={S.colRecord}>
                          <button style={S.recordBtn} onClick={() => setRecording(isRec ? null : recId)} title={t.keybindings.recordBtn}>
                            {isRec ? <IconClose size={10} /> : <IconKeyboard size={12} />}
                          </button>
                        </span>
                      </div>
                    );
                  })}
              </div>
              <div style={S.footer}>
                <button style={S.resetBtn} onClick={resetMesh}>{t.keybindings.resetToDefaults}</button>
                <span style={S.hint}>{t.keybindings.savedLocally}</span>
              </div>
            </div>
          )}

          {visibleCategories.length === 0 && (
            <div style={S.empty}>{t.keybindings.noMatch}</div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const S: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontFamily: "inherit",
    fontSize: 13,
    outline: "none",
  },
  searchBar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "10px 16px",
    borderBottom: "1px solid #313244",
    background: "#181825",
    flexShrink: 0,
  },
  searchIcon: { color: "#6c7086", fontSize: 16 },
  searchInput: {
    flex: 1,
    background: "transparent",
    border: "none",
    outline: "none",
    color: "#cdd6f4",
    fontSize: 13,
  },
  searchClear: {
    background: "none",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    padding: "2px 4px",
    borderRadius: 3,
    fontSize: 12,
  },
  body: {
    display: "flex",
    flex: 1,
    overflow: "hidden",
  },
  nav: {
    width: 120,
    borderRight: "1px solid #313244",
    padding: "8px 0",
    flexShrink: 0,
    overflowY: "auto",
  },
  navItem: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    width: "100%",
    padding: "8px 12px",
    background: "transparent",
    border: "none",
    color: "#a6adc8",
    cursor: "pointer",
    textAlign: "left" as const,
    fontSize: 12,
    borderRadius: 0,
    transition: "background 0.1s",
  },
  navItemActive: {
    background: "#313244",
    color: "#cdd6f4",
  },
  navIcon: { fontSize: 14, width: 16, textAlign: "center" as const },
  navLabel: { flex: 1 },
  content: {
    flex: 1,
    overflowY: "auto",
    padding: "16px 20px",
  },
  sectionHeader: {
    fontSize: 16,
    fontWeight: 600,
    color: "#cdd6f4",
    marginBottom: 6,
  },
  sectionDesc: {
    fontSize: 12,
    color: "#6c7086",
    marginBottom: 16,
    lineHeight: 1.5,
  },
  table: {
    display: "flex",
    flexDirection: "column",
    gap: 1,
    border: "1px solid #313244",
    borderRadius: 6,
    overflow: "hidden",
  },
  headerRow: {
    display: "flex",
    alignItems: "center",
    padding: "6px 12px",
    background: "#181825",
    fontSize: 11,
    color: "#6c7086",
    fontWeight: 600,
    letterSpacing: "0.05em",
    textTransform: "uppercase" as const,
  },
  row: {
    display: "flex",
    alignItems: "center",
    padding: "8px 12px",
    background: "#1e1e2e",
    borderTop: "1px solid #313244",
    transition: "background 0.1s",
  },
  rowRecording: {
    background: "rgba(137,180,250,0.08)",
  },
  colAction: { flex: 1, color: "#cdd6f4" },
  colKey: { width: 160, flexShrink: 0 },
  colRecord: { width: 32, flexShrink: 0, textAlign: "right" as const },
  colFixed: { width: 60, flexShrink: 0, textAlign: "right" as const },
  keyCode: {
    display: "inline-block",
    padding: "2px 6px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 4,
    fontFamily: "monospace",
    fontSize: 11,
    color: "#89b4fa",
    letterSpacing: "0.03em",
  },
  recordingBadge: {
    fontSize: 11,
    color: "#f9e2af",
    fontStyle: "italic",
  },
  recordBtn: {
    background: "transparent",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "2px 6px",
    fontSize: 12,
    lineHeight: 1,
  },
  fixedBadge: {
    fontSize: 10,
    color: "#6c7086",
    background: "#313244",
    borderRadius: 4,
    padding: "2px 6px",
  },
  footer: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    marginTop: 12,
  },
  resetBtn: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 5,
    color: "#cdd6f4",
    cursor: "pointer",
    padding: "5px 12px",
    fontSize: 12,
  },
  hint: {
    fontSize: 11,
    color: "#6c7086",
  },
  empty: {
    textAlign: "center" as const,
    color: "#6c7086",
    padding: "40px 0",
    fontSize: 13,
  },
};
