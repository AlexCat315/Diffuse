import React, { useCallback } from "react";
import { useMeshEditStore } from "../store/mesh-edit";
import type { MeshSelectionMode } from "../store/mesh-edit";
import { useI18n } from "../i18n";

/**
 * Viewport mode indicator — mirrors the Blender-style mode selector:
 *   - Mesh selected, not editing → "Object Mode ▾" entry button
 *   - Editing → "Object Mode ▸ Edit Mode | 1 2 3 | n | ✕"
 */
export function MeshEditToolbar() {
  const { t } = useI18n();
  const active = useMeshEditStore((s) => s.active);
  const selectionMode = useMeshEditStore((s) => s.selectionMode);
  const selectionCount = useMeshEditStore((s) => s.selectionCount);
  const setSelMode = useMeshEditStore((s) => s.setSelectionMode);
  const exitEditMode = useMeshEditStore((s) => s.exitEditMode);

  const stopProp = useCallback((e: React.SyntheticEvent) => e.stopPropagation(), []);

  // Not editing → show nothing
  if (!active) return null;

  // ── Edit Mode toolbar ─────────────────────────────────────────────
  const selModes: { key: MeshSelectionMode; label: string; shortcut: string }[] = [
    { key: "vertex", label: t.meshEdit.vertex, shortcut: "1" },
    { key: "edge", label: t.meshEdit.edge, shortcut: "2" },
    { key: "face", label: t.meshEdit.face, shortcut: "3" },
  ];

  return (
    <div style={styles.container} onPointerDown={stopProp} onMouseDown={stopProp} onClick={stopProp}>
      {/* V / E / F mode buttons */}
      <div style={styles.group}>
        {selModes.map(({ key, label, shortcut }) => (
          <button
            key={key}
            title={`${label} (${shortcut})`}
            style={{ ...styles.btn, ...(selectionMode === key ? styles.btnActive : {}) }}
            onClick={() => setSelMode(key)}
          >
            {shortcut}
          </button>
        ))}
      </div>

      <div style={styles.sep} />

      <span style={styles.info}>{selectionCount}</span>

      <div style={styles.sep} />

      <button style={styles.exitBtn} onClick={exitEditMode} title={`${t.meshEdit.exitEditMode} (Esc)`}>
        ✕
      </button>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "inline-flex",
    alignItems: "center",
    gap: 3,
    padding: "0 6px",
    pointerEvents: "auto",
  },
  group: {
    display: "flex",
    gap: 1,
  },
  btn: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 3,
    color: "#cdd6f4",
    cursor: "pointer",
    padding: "2px 7px",
    fontSize: 11,
    fontWeight: 600,
    lineHeight: "1",
    minWidth: 20,
    textAlign: "center" as const,
    transition: "all 0.1s",
  },
  btnActive: {
    background: "rgba(69, 71, 90, 0.8)",
    border: "1px solid #89b4fa",
    color: "#89b4fa",
  },
  sep: {
    width: 1,
    height: 14,
    background: "rgba(69, 71, 90, 0.5)",
  },
  info: {
    fontSize: 10,
    color: "#a6adc8",
    whiteSpace: "nowrap" as const,
    fontVariantNumeric: "tabular-nums",
    minWidth: 12,
    textAlign: "center" as const,
  },
  exitBtn: {
    background: "transparent",
    border: "none",
    borderRadius: 3,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "2px 4px",
    fontSize: 10,
    lineHeight: "1",
    transition: "color 0.1s",
  },
};
