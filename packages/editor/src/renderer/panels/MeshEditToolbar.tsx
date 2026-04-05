import React, { useCallback } from "react";
import { useMeshEditStore } from "../store/mesh-edit";
import type { MeshSelectionMode } from "../store/mesh-edit";
import { useI18n } from "../i18n";
import { IconMeshVertex, IconMeshEdge, IconMeshFace } from "../components/Icons";
import { Tooltip } from "../components/Tooltip";

const SEL_MODE_ICONS: Record<MeshSelectionMode, React.FC<{ size?: number; color?: string }>> = {
  vertex: IconMeshVertex,
  edge: IconMeshEdge,
  face: IconMeshFace,
};

/**
 * Viewport mesh edit mode indicator — renders in the panel title bar.
 * Hidden when not in edit mode; shows V/E/F selection mode buttons when active.
 */
export function MeshEditToolbar() {
  const { t } = useI18n();
  const active = useMeshEditStore((s) => s.active);
  const selectionMode = useMeshEditStore((s) => s.selectionMode);
  const selectionCount = useMeshEditStore((s) => s.selectionCount);
  const setSelMode = useMeshEditStore((s) => s.setSelectionMode);

  const stopProp = useCallback((e: React.SyntheticEvent) => e.stopPropagation(), []);

  // Not editing → show nothing
  if (!active) return null;

  // ── Edit Mode toolbar ─────────────────────────────────────────────
  const selModes: { key: MeshSelectionMode; label: string; shortcut: string }[] = [
    { key: "vertex", label: t.meshEdit.vertex, shortcut: "1" },
    { key: "edge",   label: t.meshEdit.edge,   shortcut: "2" },
    { key: "face",   label: t.meshEdit.face,   shortcut: "3" },
  ];

  return (
    <div style={styles.container} onPointerDown={stopProp} onMouseDown={stopProp} onClick={stopProp}>
      <div style={styles.group}>
        {selModes.map(({ key, label, shortcut }) => {
          const Icon = SEL_MODE_ICONS[key];
          const active = selectionMode === key;
          return (
            <Tooltip key={key} label={label} shortcut={shortcut}>
              <button
                style={{ ...styles.btn, ...(active ? styles.btnActive : {}) }}
                onClick={() => setSelMode(key)}
              >
                <Icon size={14} color={active ? "#89b4fa" : "#a6adc8"} />
              </button>
            </Tooltip>
          );
        })}
      </div>

      <div style={styles.sep} />

      <span style={styles.info}>{selectionCount}</span>
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
};
