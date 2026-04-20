import React, { useCallback, useState } from "react";
import { useLocalState } from "../store/local-state";
import type { GizmoMode } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import {
  IconSave, IconFolderOpen, IconUndo, IconRedo,
  IconPlay, IconPause, IconStop,
  IconTranslate, IconRotate, IconScale, IconCursor,
  IconBuild, IconGrid, IconSettings,
} from "../components/Icons";
import { Tooltip } from "../components/Tooltip";
import { useSceneStore } from "../store";
import { toast } from "../store/toast";
import { BuildDialog } from "../components/BuildDialog";
import { engine } from "../engine-client";
import { buildPackage, runBuiltGame, platform } from "../citron-api";

interface ToolbarProps {
  onResetLayout?: () => void;
  onOpenSettings?: () => void;
}

export function Toolbar({ onResetLayout, onOpenSettings }: ToolbarProps) {
  const gizmoMode = useSceneStore((s) => s.gizmoMode);
  const onGizmoModeChange = useSceneStore((s) => s.changeGizmoMode);
  const onRefreshHierarchy = useSceneStore((s) => s.refreshHierarchy);
  const sceneDirty = useSceneStore((s) => s.sceneRevision !== s.savedRevision);
  const markSaved = useSceneStore((s) => s.markSaved);
  const playbackState = useSceneStore((s) => s.playbackState);
  const { t } = useI18n();
  const [sceneMenuOpen, setSceneMenuOpen] = useLocalState(false);
  const [scenes, setScenes] = useLocalState<string[]>([]);
  const [buildOpen, setBuildOpen] = useState(false);
  const [runningBuild, setRunningBuild] = useState(false);

  const handleQuickRun = useCallback(async () => {
    if (runningBuild) return;
    setRunningBuild(true);
    try {
      const res = await buildPackage({ optimize: "Debug" }) as { ok: boolean; path?: string; error?: string };
      if (res.ok && res.path) {
        await runBuiltGame(res.path);
      } else {
        toast.error(res.error ?? "Build failed");
      }
    } catch (e) {
      toast.error(`Quick Run failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setRunningBuild(false);
    }
  }, [runningBuild]);

  const setPlaybackState = useSceneStore((s) => s.setPlaybackState);
  const handlePlay = async () => {
    try {
      if (sceneDirty) {
        const res = await engine.call("scene.save", {}) as { path: string; revision?: number };
        markSaved(res.revision);
      }
      setPlaybackState("playing");
      await engine.call("playback.play", {});
    } catch (e) {
      setPlaybackState("stopped");
      toast.error(`Play failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  };
  const handlePause = () => {
    setPlaybackState("paused");
    engine.call("playback.pause", {}).catch(() => setPlaybackState("stopped"));
  };
  const handleStop = () => {
    setPlaybackState("stopped");
    engine.call("playback.stop", {})
      .then(() => onRefreshHierarchy?.())
      .catch((e) => toast.error(`Stop failed: ${e instanceof Error ? e.message : String(e)}`));
  };
  const handleUndo = () => {
    engine.call("editor.undo", {})
      .catch((e) => toast.warn(`Undo failed: ${e instanceof Error ? e.message : String(e)}`));
  };
  const handleRedo = () => {
    engine.call("editor.redo", {})
      .catch((e) => toast.warn(`Redo failed: ${e instanceof Error ? e.message : String(e)}`));
  };

  const handleSave = useCallback(() => {
    engine.call("scene.save", {})
      .then((res: { path: string; revision?: number }) => {
        markSaved(res.revision);
        toast.success("Scene saved");
      })
      .catch((e) => toast.error(`Save failed: ${e instanceof Error ? e.message : String(e)}`));
  }, [markSaved]);

  const handleOpenSceneMenu = useCallback(async () => {
    if (sceneMenuOpen) {
      setSceneMenuOpen(false);
      return;
    }
    try {
      const result = await engine.call("scene.listScenes", {});
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
        await engine.call("scene.load", { path });
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
        <ToolButton
          icon={<IconSave size={14} />}
          tooltip={t.toolbar.save}
          onClick={handleSave}
          highlight={sceneDirty}
        />
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
        <ToolButton icon={<IconPlay size={14} />} tooltip={t.toolbar.play} onClick={handlePlay}
          active={playbackState === "playing"} />
        <ToolButton icon={<IconPause size={14} />} tooltip={t.toolbar.pause} onClick={handlePause}
          active={playbackState === "paused"} />
        <ToolButton icon={<IconStop size={14} />} tooltip={t.toolbar.stop} onClick={handleStop}
          active={playbackState === "stopped"} />
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton icon={<IconCursor size={14} />} tooltip={t.toolbar.select}
          active={gizmoMode === "none"}
          onClick={() => onGizmoModeChange("none")}
        />
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
        <ToolButton
          icon={<IconBuild size={14} />}
          tooltip="Build Standalone Game"
          onClick={() => setBuildOpen(true)}
        />
        <ToolButton
          icon={<IconPlay size={14} color={runningBuild ? "#6c7086" : "#a6e3a1"} />}
          tooltip={runningBuild ? "Building..." : "Quick Run (Build & Launch)"}
          onClick={handleQuickRun}
        />
        <div style={styles.divider} />
        {onResetLayout && (
          <ToolButton
            icon={<IconGrid size={12} />}
            tooltip={t.toolbar.resetLayout}
            onClick={onResetLayout}
          />
        )}
        {onOpenSettings && (
          <ToolButton
            icon={<IconSettings size={14} />}
            tooltip={t.toolbar.settings}
            onClick={onOpenSettings}
          />
        )}
        <span style={styles.brand}>{t.toolbar.brand}</span>
      </div>
      <BuildDialog open={buildOpen} onClose={() => setBuildOpen(false)} />
    </div>
  );
}

function ToolButton({
  icon,
  tooltip,
  onClick,
  active,
  highlight,
}: {
  icon: React.ReactNode;
  tooltip: string;
  onClick?: () => void;
  active?: boolean;
  highlight?: boolean;
}) {
  // Parse "Label (Shortcut)" → label + shortcut for the styled Tooltip
  const match = tooltip.match(/^(.+?)\s*\(([^)]+)\)$/);
  const label = match ? match[1] : tooltip;
  const shortcut = match ? match[2] : undefined;

  return (
    <Tooltip label={label} shortcut={shortcut} placement="bottom">
      <button
        style={{
          ...styles.button,
          ...(active && {
            background: "#45475a",
            border: "1px solid #89b4fa",
            color: "#89b4fa",
          }),
          ...(highlight && {
            color: "#f9e2af",
          }),
        }}
        onClick={onClick}
      >
        {icon}
      </button>
    </Tooltip>
  );
}

const styles = {
  toolbar: {
    display: "flex",
    alignItems: "center",
    padding: "4px 12px",
    paddingLeft: platform === "darwin" ? 80 : 12,
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
    borderRadius: 5,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "5px 8px",
    fontSize: 14,
    lineHeight: 1,
    transition: "all 0.15s",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
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
