import React, { useCallback } from "react";
import { useMeshEditStore } from "../store/mesh-edit";
import type { MeshSelectionMode } from "../store/mesh-edit";
import { useI18n } from "../i18n";

/**
 * Floating toolbar overlaid on the Viewport when mesh editing is active.
 * Shows selection mode toggles (V/E/F) and common mesh operations.
 */
export function MeshEditToolbar() {
  const { t } = useI18n();
  const active = useMeshEditStore((s) => s.active);
  const canEnterEditMode = useMeshEditStore((s) => s.canEnterEditMode);
  const selectionMode = useMeshEditStore((s) => s.selectionMode);
  const selectionCount = useMeshEditStore((s) => s.selectionCount);
  const setSelMode = useMeshEditStore((s) => s.setSelectionMode);
  const enterEditMode = useMeshEditStore((s) => s.enterEditMode);
  const exitEditMode = useMeshEditStore((s) => s.exitEditMode);

  const extrude = useMeshEditStore((s) => s.extrude);
  const inset = useMeshEditStore((s) => s.inset);
  const bevel = useMeshEditStore((s) => s.bevel);
  const loopCut = useMeshEditStore((s) => s.loopCut);
  const merge = useMeshEditStore((s) => s.merge);
  const deleteMesh = useMeshEditStore((s) => s.deleteMesh);
  const duplicate = useMeshEditStore((s) => s.duplicate);
  const separate = useMeshEditStore((s) => s.separate);
  const recalcNormals = useMeshEditStore((s) => s.recalcNormals);
  const pivotToSelection = useMeshEditStore((s) => s.pivotToSelection);

  const handleSelMode = useCallback(
    (mode: MeshSelectionMode) => {
      setSelMode(mode);
    },
    [setSelMode],
  );

  // Show "Enter Edit Mode" prompt when a mesh entity is selected but not editing
  if (!active && canEnterEditMode) {
    return (
      <div style={styles.container}>
        <button style={styles.enterBtn} onClick={() => enterEditMode()}>
          {t.meshEdit.enterEditMode} (Tab)
        </button>
      </div>
    );
  }

  if (!active) return null;

  const selModes: { key: MeshSelectionMode; label: string; shortcut: string }[] = [
    { key: "vertex", label: t.meshEdit.vertex, shortcut: "1" },
    { key: "edge", label: t.meshEdit.edge, shortcut: "2" },
    { key: "face", label: t.meshEdit.face, shortcut: "3" },
  ];

  const ops: { label: string; action: () => void; shortcut?: string }[] = [
    { label: t.meshEdit.extrude, action: extrude, shortcut: "E" },
    { label: t.meshEdit.inset, action: inset, shortcut: "I" },
    { label: t.meshEdit.bevel, action: bevel, shortcut: "B" },
    { label: t.meshEdit.loopCut, action: loopCut, shortcut: "Ctrl+R" },
    { label: t.meshEdit.merge, action: merge, shortcut: "M" },
    { label: t.meshEdit.delete, action: deleteMesh, shortcut: "X" },
    { label: t.meshEdit.duplicate, action: duplicate, shortcut: "Shift+D" },
    { label: t.meshEdit.separate, action: separate },
    { label: t.meshEdit.recalcNormals, action: recalcNormals },
    { label: t.meshEdit.pivotToSelection, action: pivotToSelection },
  ];

  return (
    <div style={styles.container}>
      {/* Selection mode buttons */}
      <div style={styles.group}>
        {selModes.map(({ key, label, shortcut }) => (
          <button
            key={key}
            title={`${label} (${shortcut})`}
            style={{
              ...styles.btn,
              ...(selectionMode === key ? styles.btnActive : {}),
            }}
            onClick={() => handleSelMode(key)}
          >
            {shortcut}
          </button>
        ))}
      </div>

      <div style={styles.sep} />

      {/* Selection count */}
      <span style={styles.info}>
        {t.meshEdit.selectionCount}: {selectionCount}
      </span>

      <div style={styles.sep} />

      {/* Operations (scrollable) */}
      <div style={styles.opsGroup}>
        {ops.map(({ label, action, shortcut }) => (
          <button
            key={label}
            title={shortcut ? `${label} (${shortcut})` : label}
            style={styles.opBtn}
            onClick={action}
          >
            {label}
          </button>
        ))}
      </div>

      <div style={styles.sep} />

      {/* Exit edit mode */}
      <button style={styles.exitBtn} onClick={exitEditMode}>
        {t.meshEdit.exitEditMode} (Tab)
      </button>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    position: "absolute",
    top: 8,
    left: "50%",
    transform: "translateX(-50%)",
    zIndex: 15,
    display: "flex",
    alignItems: "center",
    gap: 4,
    background: "rgba(24, 24, 37, 0.85)",
    backdropFilter: "blur(8px)",
    WebkitBackdropFilter: "blur(8px)",
    borderRadius: 6,
    padding: "3px 6px",
    boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
    border: "1px solid rgba(137, 180, 250, 0.4)",
    maxWidth: "90%",
  },
  group: {
    display: "flex",
    gap: 2,
  },
  opsGroup: {
    display: "flex",
    gap: 2,
    flexWrap: "wrap",
  },
  btn: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    color: "#cdd6f4",
    cursor: "pointer",
    padding: "3px 8px",
    fontSize: 11,
    fontWeight: 600,
    lineHeight: "1",
    minWidth: 22,
    textAlign: "center" as const,
    transition: "all 0.1s",
  },
  btnActive: {
    background: "rgba(69, 71, 90, 0.8)",
    border: "1px solid #89b4fa",
    color: "#89b4fa",
  },
  opBtn: {
    background: "rgba(49, 50, 68, 0.6)",
    border: "1px solid rgba(69, 71, 90, 0.4)",
    borderRadius: 4,
    color: "#cdd6f4",
    cursor: "pointer",
    padding: "3px 6px",
    fontSize: 10,
    lineHeight: "1",
    transition: "all 0.1s",
    whiteSpace: "nowrap" as const,
  },
  sep: {
    width: 1,
    alignSelf: "stretch",
    margin: "2px 2px",
    background: "rgba(69, 71, 90, 0.6)",
  },
  info: {
    fontSize: 10,
    color: "#a6adc8",
    whiteSpace: "nowrap" as const,
    padding: "0 4px",
  },
  enterBtn: {
    background: "rgba(137, 180, 250, 0.15)",
    border: "1px solid rgba(137, 180, 250, 0.5)",
    borderRadius: 4,
    color: "#89b4fa",
    cursor: "pointer",
    padding: "4px 10px",
    fontSize: 11,
    fontWeight: 600,
    lineHeight: "1",
    transition: "all 0.1s",
    whiteSpace: "nowrap" as const,
  },
  exitBtn: {
    background: "rgba(243, 139, 168, 0.12)",
    border: "1px solid rgba(243, 139, 168, 0.4)",
    borderRadius: 4,
    color: "#f38ba8",
    cursor: "pointer",
    padding: "3px 6px",
    fontSize: 10,
    lineHeight: "1",
    transition: "all 0.1s",
    whiteSpace: "nowrap" as const,
  },
};
