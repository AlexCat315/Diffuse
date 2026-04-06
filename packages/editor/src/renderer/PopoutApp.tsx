import React, { useEffect, useCallback, useState } from "react";
import type { GuavaEngineAPI } from "../preload/preload";
import { SceneHierarchy } from "./panels/SceneHierarchy";
import { Inspector } from "./panels/Inspector";
import { Console } from "./panels/Console";
import { Viewport } from "./panels/Viewport";
import { RenderSettingsPanel } from "./panels/RenderSettings";
import { MaterialEditor } from "./panels/MaterialEditor";
import { AssetBrowser } from "./panels/AssetBrowser";
import { CommandTimeline } from "./panels/CommandTimeline";
import { EditorUtilities } from "./panels/EditorUtilities";
import { CameraBookmarks } from "./panels/CameraBookmarks";
import { RhiStats } from "./panels/RhiStats";
import { AudioMixer } from "./panels/AudioMixer";
import { PluginManager } from "./panels/PluginManager";
import { StyleInspector } from "./panels/StyleInspector";
import { PlaceActors } from "./panels/PlaceActors";
import { RenderQueue } from "./panels/RenderQueue";
import { PhysicsVisualization } from "./panels/PhysicsVisualization";
import { PostProcessEditor } from "./panels/PostProcessEditor";
import { SequencerPanel } from "./panels/SequencerPanel";
import { AnimationEditor } from "./panels/AnimationEditor";
import { MaterialGraphEditor } from "./panels/MaterialGraphEditor";
import { ScriptViewer } from "./panels/ScriptViewer";
import { AiChat } from "./panels/AiChat";
import { ParticleEditor } from "./panels/ParticleEditor";
import { PrefabEditor } from "./panels/PrefabEditor";
import { SkyPanel } from "./panels/SkyPanel";
import { AssetManager } from "./panels/AssetManager";
import { SettingsPanel } from "./panels/Settings";
import { useI18n } from "./i18n";
import {
  useConnectionStore,
  useConsoleStore,
  useSceneStore,
  initRpcBridge,
} from "./store";

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}

const PANEL_LABELS: Record<string, string> = {
  hierarchy: "Scene Hierarchy",
  inspector: "Inspector",
  viewport: "Viewport",
  material: "Material",
  rendersettings: "Render Settings",
  console: "Console",
  assets: "Content Browser",
  timeline: "Timeline",
  utilities: "AI Utilities",
  camera: "Camera",
  rhistats: "RHI Stats",
  audio: "Audio",
  plugins: "Plugins",
  style: "Style",
  placeactors: "Place Actors",
  renderqueue: "Render Queue",
  physicsviz: "Physics",
  postprocess: "Post-FX",
  sequencer: "Sequencer",
  animationeditor: "Animation",
  materialgraph: "Material Graph",
  scriptviewer: "Scripts",
  aichat: "AI Chat",
  particleeditor: "Particles",
  prefabeditor: "Prefabs",
  sky: "Sky",
  assetmanager: "Asset Manager",
  settings: "Settings",
};

function PanelContent({ panelId }: { panelId: string }) {
  switch (panelId) {
    case "viewport":        return <Viewport />;
    case "hierarchy":       return <SceneHierarchy />;
    case "inspector":       return <Inspector />;
    case "material":        return <MaterialEditor />;
    case "rendersettings":  return <RenderSettingsPanel />;
    case "console":         return <Console />;
    case "assets":          return <AssetBrowser />;
    case "timeline":        return <CommandTimeline />;
    case "utilities":       return <EditorUtilities />;
    case "camera":          return <CameraBookmarks />;
    case "rhistats":        return <RhiStats />;
    case "audio":           return <AudioMixer />;
    case "plugins":         return <PluginManager />;
    case "style":           return <StyleInspector />;
    case "placeactors":     return <PlaceActors />;
    case "renderqueue":     return <RenderQueue />;
    case "physicsviz":      return <PhysicsVisualization />;
    case "postprocess":     return <PostProcessEditor />;
    case "sequencer":       return <SequencerPanel />;
    case "animationeditor": return <AnimationEditor />;
    case "materialgraph":   return <MaterialGraphEditor />;
    case "scriptviewer":    return <ScriptViewer />;
    case "aichat":          return <AiChat />;
    case "particleeditor":  return <ParticleEditor />;
    case "prefabeditor":    return <PrefabEditor />;
    case "sky":             return <SkyPanel />;
    case "assetmanager":    return <AssetManager />;
    case "settings":        return <SettingsPanel />;
    default:
      return <div style={{ padding: 12, color: "#6c7086" }}>Unknown panel: {panelId}</div>;
  }
}

export function PopoutApp({ panels }: { panels: string[] }) {
  const { t } = useI18n();
  const panelLabels = t.panels as Record<string, string>;
  const connected = useConnectionStore((s) => s.connected);
  const error = useConnectionStore((s) => s.error);
  const [activePanel, setActivePanel] = useState(panels[0] ?? "");

  useEffect(() => {
    const cleanup = initRpcBridge();

    // Hydrate stores from initial state pushed by main window
    const cleanupInit = window.guavaEngine.onInitState((state: unknown) => {
      const s = state as {
        consoleLogs?: Array<{ level: string; message: string; category?: string; timestamp?: number }>;
        sceneHierarchy?: unknown[];
        selectedEntity?: number | null;
        gizmoMode?: string;
      };
      if (s.consoleLogs) {
        const store = useConsoleStore.getState();
        for (const entry of s.consoleLogs) {
          store.appendLog(entry as never);
        }
      }
      if (s.sceneHierarchy) {
        useSceneStore.getState().setHierarchy(s.sceneHierarchy as never);
      }
      if (s.selectedEntity !== undefined) {
        useSceneStore.getState().setSelectedEntity(s.selectedEntity);
      }
    });

    return () => {
      cleanup();
      cleanupInit();
    };
  }, []);

  // Set window title
  useEffect(() => {
    const label = panels.map((p) => PANEL_LABELS[p] ?? p).join(" / ");
    document.title = `${label} — Guava Editor`;
  }, [panels]);

  const handleClose = useCallback(() => {
    window.guavaEngine.closePopout();
  }, []);

  if (error) {
    return (
      <div style={styles.center}>
        <p style={{ color: "#f38ba8" }}>{error}</p>
      </div>
    );
  }

  if (!connected) {
    return (
      <div style={styles.center}>
        <div style={styles.spinner} />
        <p style={{ color: "#a6adc8" }}>Connecting to engine...</p>
      </div>
    );
  }

  return (
    <div style={styles.root}>
      {/* Tab bar (only shown if multiple panels) */}
      {panels.length > 1 && (
        <div style={styles.tabBar}>
          {panels.map((p) => (
            <button
              key={p}
              style={p === activePanel ? styles.tabActive : styles.tab}
              onClick={() => setActivePanel(p)}
            >
              {panelLabels[p] ?? p}
            </button>
          ))}
          <div style={{ flex: 1 }} />
          <button style={styles.closeBtn} onClick={handleClose} title={t.app.closePopout}>✕</button>
        </div>
      )}
      {/* Single panel: no tabs, just a minimal title bar */}
      {panels.length === 1 && (
        <div style={styles.titleBar}>
          <span style={styles.titleText}>{panelLabels[activePanel] ?? activePanel}</span>
          <button style={styles.closeBtn} onClick={handleClose} title={t.app.closePopout}>✕</button>
        </div>
      )}
      {/* Panel content */}
      <div style={styles.content}>
        <PanelContent panelId={activePanel} />
      </div>
    </div>
  );
}

const styles = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    background: "#1e1e2e",
    color: "#cdd6f4",
  },
  center: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    height: "100vh",
    gap: 12,
    background: "#1e1e2e",
  },
  titleBar: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "6px 12px",
    background: "#181825",
    borderBottom: "1px solid #313244",
    userSelect: "none",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any,
  titleText: {
    fontSize: 12,
    fontWeight: 600,
    color: "#cdd6f4",
  },
  tabBar: {
    display: "flex",
    alignItems: "center",
    gap: 0,
    background: "#181825",
    borderBottom: "1px solid #313244",
    userSelect: "none",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any,
  tab: {
    padding: "6px 14px",
    fontSize: 12,
    color: "#6c7086",
    background: "transparent",
    border: "none",
    borderBottom: "2px solid transparent",
    cursor: "pointer",
  },
  tabActive: {
    padding: "6px 14px",
    fontSize: 12,
    color: "#cdd6f4",
    background: "transparent",
    border: "none",
    borderBottom: "2px solid #89b4fa",
    cursor: "pointer",
  },
  closeBtn: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 14,
    padding: "4px 8px",
    borderRadius: 4,
  },
  content: {
    flex: 1,
    overflow: "hidden",
    position: "relative" as const,
  },
  spinner: {
    width: 20,
    height: 20,
    border: "2px solid #45475a",
    borderTop: "2px solid #89b4fa",
    borderRadius: "50%",
    animation: "spin 1s linear infinite",
  },
} satisfies Record<string, React.CSSProperties | (React.CSSProperties & Record<string, unknown>)>;
