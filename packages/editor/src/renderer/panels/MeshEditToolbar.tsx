import React, { useCallback } from "react";
import { useMeshEditStore } from "../store/mesh-edit";
import { useViewportSettingsStore } from "../store";
import type { MeshSelectionMode } from "../store/mesh-edit";
import { useI18n } from "../i18n";

/**
 * Compact mode indicator overlaid on the Viewport during mesh editing.
 * Shows V/E/F selection mode toggles and selection count.
 * Enter: double-click entity | Exit: Escape or double-click again
 * Mesh operations are in the context menu (right-click).
 */
export function MeshEditToolbar() {
  const { t } = useI18n();
  const active = useMeshEditStore((s) => s.active);
  const selectionMode = useMeshEditStore((s) => s.selectionMode);
  const selectionCount = useMeshEditStore((s) => s.selectionCount);
  const setSelMode = useMeshEditStore((s) => s.setSelectionMode);
  const exitEditMode = useMeshEditStore((s) => s.exitEditMode);

  const handleSelMode = useCallback(
    (mode: MeshSelectionMode) => {
      setSelMode(mode);
    },
    [setSelMode],
  );

  const handleExit = useCallback(() => {
    exitEditMode();
    if (useViewportSettingsStore.getState().shadingMode === "wireframe") {
      useViewportSettingsStore.getState().setShadingMode("solid");
    }
  }, [exitEditMode]);

  if (!active) return null;

  const selModes: { key: MeshSelectionMode; label: string; shortcut: string }[] = [
    { key: "vertex", label: t.meshEdit.vertex, shortcut: "1" },
    { key: "edge", label: t.meshEdit.edge, shortcut: "2" },
    { key: "face", label: t.meshEdit.face, shortcut: "3" },
  ];

  return (
    // Stop pointer/mouse events from reaching the viewport canvas
    <div
      style={styles.container}
      onPointerDown={(e) => e.stopPropagation()}
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <span style={styles.modeLabel}>{t.meshEdit.editMode}</span>

      <div style={styles.sep} />

      {/* V / E / F mode buttons */}
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

      <span style={styles.info}>{selectionCount}</span>

      <div style={styles.sep} />

      <button style={styles.exitBtn} onClick={handleExit} title="Escape">
        ✕
      </button>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    position: "absolute",
    top: 6,
    left: "50%",
    transform: "translateX(-50%)",
    zIndex: 15,
    display: "flex",
    alignItems: "center",
    gap: 3,
    background: "rgba(24, 24, 37, 0.88)",
    backdropFilter: "blur(8px)",
    WebkitBackdropFilter: "blur(8px)",
    borderRadius: 5,
    padding: "2px 6px",
    boxShadow: "0 1px 4px rgba(0,0,0,0.25)",
    border: "1px solid rgba(137, 180, 250, 0.35)",
    pointerEvents: "auto",
  },
  modeLabel: {
    fontSize: 10,
    fontWeight: 600,
    color: "#89b4fa",
    whiteSpace: "nowrap" as const,
    padding: "0 2px",
    letterSpacing: 0.3,
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
