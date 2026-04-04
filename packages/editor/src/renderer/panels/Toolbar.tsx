import React, { useState, useCallback } from "react";
import type { GizmoMode } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import {
  IconSave, IconFolderOpen, IconUndo, IconRedo,
  IconPlay, IconPause, IconStop,
  IconTranslate, IconRotate, IconScale,
} from "../components/Icons";
import { useSceneStore } from "../store";

interface ToolbarProps {
  onResetLayout?: () => void;
  onOpenSettings?: () => void;
}

export function Toolbar({ onResetLayout, onOpenSettings }: ToolbarProps) {
  const gizmoMode = useSceneStore((s) => s.gizmoMode);
  const onGizmoModeChange = useSceneStore((s) => s.changeGizmoMode);
  const onRefreshHierarchy = useSceneStore((s) => s.refreshHierarchy);
  const { t } = useI18n();
  const [sceneMenuOpen, setSceneMenuOpen] = useState(false);
  const [scenes, setScenes] = useState<string[]>([]);

  const handlePlay = () => window.guavaEngine.call("playback.play", {});
  const handlePause = () => window.guavaEngine.call("playback.pause", {});
  const handleStop = () => window.guavaEngine.call("playback.stop", {});
  const handleUndo = () => window.guavaEngine.call("editor.undo", {});
  const handleRedo = () => window.guavaEngine.call("editor.redo", {});

  const handleSave = useCallback(() => {
    window.guavaEngine.call("scene.save", {}).catch((e) => console.error("Save failed:", e));
  }, []);

  const handleOpenSceneMenu = useCallback(async () => {
    if (sceneMenuOpen) {
      setSceneMenuOpen(false);
      return;
    }
    try {
      const result = await window.guavaEngine.call("scene.listScenes", {});
      setScenes(result.scenes);
    } catch {
      setScenes([]);
    }
    setSceneMenuOpen(true);
  }, [sceneMenuOpen]);

  const handleLoadScene = useCallback(
    async (path: string) => {
      setSceneMenuOpen(false);
      try {
        await window.guavaEngine.call("scene.load", { path });
        onRefreshHierarchy?.();
      } catch (e) {
        console.error("Load failed:", e);
      }
    },
    [onRefreshHierarchy],
  );

  return (
    <div style={styles.toolbar}>
      <div style={styles.section}>
        <ToolButton icon={<IconSave size={14} />} tooltip={t.toolbar.save} onClick={handleSave} />
        <div style={{ position: "relative" }}>
          <ToolButton icon={<IconFolderOpen size={14} />} tooltip={t.toolbar.openScene} onClick={handleOpenSceneMenu} />
          {sceneMenuOpen && (
            <div style={styles.dropdown}>
              {scenes.length === 0 ? (
                <div style={styles.dropdownItem}>{t.toolbar.noScenesFound}</div>
              ) : (
                scenes.map((s) => (
                  <div
                    key={s}
                    style={styles.dropdownItem}
                    onClick={() => handleLoadScene(s)}
                    onMouseEnter={(e) => (e.currentTarget.style.background = "#45475a")}
                    onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
                  >
                    {s.replace("assets/scenes/", "")}
                  </div>
                ))
              )}
            </div>
          )}
        </div>
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton icon={<IconUndo size={14} />} tooltip={t.toolbar.undo} onClick={handleUndo} />
        <ToolButton icon={<IconRedo size={14} />} tooltip={t.toolbar.redo} onClick={handleRedo} />
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton icon={<IconPlay size={14} />} tooltip={t.toolbar.play} onClick={handlePlay} />
        <ToolButton icon={<IconPause size={14} />} tooltip={t.toolbar.pause} onClick={handlePause} />
        <ToolButton icon={<IconStop size={14} />} tooltip={t.toolbar.stop} onClick={handleStop} />
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton
          icon={<IconTranslate size={14} />}
          tooltip={t.toolbar.translate}
          active={gizmoMode === "translate"}
          onClick={() => onGizmoModeChange("translate")}
        />
        <ToolButton
          icon={<IconRotate size={14} />}
          tooltip={t.toolbar.rotate}
          active={gizmoMode === "rotate"}
          onClick={() => onGizmoModeChange("rotate")}
        />
        <ToolButton
          icon={<IconScale size={14} />}
          tooltip={t.toolbar.scale}
          active={gizmoMode === "scale"}
          onClick={() => onGizmoModeChange("scale")}
        />
      </div>
      <div style={{ flex: 1 }} />
      <div style={styles.section}>
        {onResetLayout && (
          <ToolButton
            icon={<span style={{ fontSize: 12 }}>⊞</span>}
            tooltip="Reset Layout"
            onClick={onResetLayout}
          />
        )}
        {onOpenSettings && (
          <ToolButton
            icon={<span style={{ fontSize: 14 }}>⚙</span>}
            tooltip="Settings"
            onClick={onOpenSettings}
          />
        )}
        <span style={styles.brand}>{t.toolbar.brand}</span>
      </div>
    </div>
  );
}

function ToolButton({
  icon,
  tooltip,
  onClick,
  active,
}: {
  icon: React.ReactNode;
  tooltip: string;
  onClick?: () => void;
  active?: boolean;
}) {
  return (
    <button
      style={{
        ...styles.button,
        ...(active && {
          background: "#45475a",
          borderColor: "#89b4fa",
          color: "#89b4fa",
        }),
      }}
      title={tooltip}
      onClick={onClick}
    >
      {icon}
    </button>
  );
}

const styles = {
  toolbar: {
    display: "flex",
    alignItems: "center",
    padding: "4px 12px",
    paddingLeft: window.guavaEngine?.platform === "darwin" ? 80 : 12,
    background: "#181825",
    borderBottom: "1px solid #313244",
    gap: 4,
    minHeight: 36,
    WebkitAppRegion: "drag",
  } as React.CSSProperties,
  section: {
    display: "flex",
    alignItems: "center",
    gap: 2,
    WebkitAppRegion: "no-drag",
  } as React.CSSProperties,
  divider: {
    width: 1,
    height: 20,
    background: "#313244",
    margin: "0 6px",
  },
  button: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "4px 8px",
    fontSize: 14,
    lineHeight: 1,
    transition: "all 0.1s",
  },
  brand: {
    fontSize: 11,
    color: "#585b70",
    fontWeight: 600,
    letterSpacing: 0.5,
    WebkitAppRegion: "drag",
  } as React.CSSProperties,
  dropdown: {
    position: "absolute" as const,
    top: "100%",
    left: 0,
    marginTop: 4,
    minWidth: 200,
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 6,
    boxShadow: "0 4px 12px rgba(0,0,0,0.4)",
    zIndex: 100,
    overflow: "hidden",
  } as React.CSSProperties,
  dropdownItem: {
    padding: "6px 12px",
    cursor: "pointer",
    fontSize: 12,
    color: "#cdd6f4",
  } as React.CSSProperties,
};
