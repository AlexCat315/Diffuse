import React, { useEffect, useCallback, useRef } from "react";
import { Layout, Model, Actions, DockLocation, type IJsonModel, type TabNode } from "flexlayout-react";
import "flexlayout-react/style/light.css";
import "./flexlayout-dark.css";

import type { GuavaEngineAPI } from "../preload/preload";
import { SceneHierarchy } from "./panels/SceneHierarchy";
import { Inspector } from "./panels/Inspector";
import { Console } from "./panels/Console";
import { Toolbar } from "./panels/Toolbar";
import { Viewport } from "./panels/Viewport";
import { RenderSettingsPanel } from "./panels/RenderSettings";
import { MaterialEditor } from "./panels/MaterialEditor";
import { AssetBrowser } from "./panels/AssetBrowser";
import { ViewportStatus } from "./panels/ViewportStatus";
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
import { SettingsPanel } from "./panels/Settings";
import { useI18n } from "./i18n";
import {
  useConnectionStore,
  useSceneStore,
  useConsoleStore,
  useEditorStore,
  initRpcBridge,
} from "./store";

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}

// ── All panels available in the editor ──────────────────
const ALL_PANELS: { id: string; name: string }[] = [
  { id: "hierarchy", name: "Scene Hierarchy" },
  { id: "inspector", name: "Inspector" },
  { id: "viewport", name: "Viewport" },
  { id: "material", name: "Material" },
  { id: "rendersettings", name: "Render Settings" },
  { id: "console", name: "Console" },
  { id: "assets", name: "Assets" },
  { id: "timeline", name: "Timeline" },
  { id: "utilities", name: "AI Utilities" },
  { id: "camera", name: "Camera" },
  { id: "rhistats", name: "RHI Stats" },
  { id: "audio", name: "Audio" },
  { id: "plugins", name: "Plugins" },
  { id: "style", name: "Style" },
  { id: "placeactors", name: "Place Actors" },
  { id: "renderqueue", name: "Render Queue" },
  { id: "physicsviz", name: "Physics" },
  { id: "postprocess", name: "Post-FX" },
  { id: "sequencer", name: "Sequencer" },
  { id: "animationeditor", name: "Animation" },
  { id: "materialgraph", name: "Material Graph" },
  { id: "scriptviewer", name: "Scripts" },
  { id: "aichat", name: "AI Chat" },
  { id: "particleeditor", name: "Particles" },
  { id: "prefabeditor", name: "Prefabs" },
];

// ── Layout storage key ──────────────────────────────────
const LAYOUT_STORAGE_KEY = "guava-editor-layout-v1";

// ── Default docking layout ──────────────────────────────
// Structure:  Toolbar (top bar, outside dock)
//   ┌──────────┬────────────────────┬───────────┐
//   │ Hierarchy│     Viewport       │ Inspector │
//   │          │                    │ Material  │
//   │          │                    │ RenderSet │
//   ├──────────┴────────────────────┴───────────┤
//   │  Console | Assets | Timeline | ...tabs    │
//   └───────────────────────────────────────────┘
//   ViewportStatus (bottom bar, outside dock)

const defaultLayout: IJsonModel = {
  global: {
    tabEnableClose: true,
    tabEnableRename: false,
    tabSetEnableMaximize: true,
    tabSetEnableDeleteWhenEmpty: false,
    splitterSize: 4,
    splitterExtra: 4,
    tabSetMinHeight: 100,
    tabSetMinWidth: 100,
  },
  borders: [],
  layout: {
    type: "row",
    weight: 100,
    children: [
      {
        // Vertical split: [top area | bottom panels]
        type: "row",
        weight: 100,
        children: [
          {
            // Top area: [left | center | right]
            type: "row",
            weight: 70,
            children: [
              {
                // Left: Scene Hierarchy
                type: "tabset",
                weight: 15,
                children: [
                  { type: "tab", name: "Scene Hierarchy", component: "hierarchy", enableClose: false },
                  { type: "tab", name: "Place Actors", component: "placeactors" },
                ],
              },
              {
                // Center: Viewport (the main attraction)
                type: "tabset",
                weight: 55,
                id: "viewport-tabset",
                children: [
                  { type: "tab", name: "Viewport", component: "viewport", enableClose: false, enableDrag: false },
                ],
              },
              {
                // Right: Inspector + Material + Render Settings
                type: "tabset",
                weight: 20,
                children: [
                  { type: "tab", name: "Inspector", component: "inspector", enableClose: false },
                  { type: "tab", name: "Material", component: "material" },
                  { type: "tab", name: "Render Settings", component: "rendersettings" },
                ],
              },
            ],
          },
          {
            // Bottom: Console, Assets, and other tool tabs
            type: "tabset",
            weight: 30,
            children: [
              { type: "tab", name: "Console", component: "console", enableClose: false },
              { type: "tab", name: "Assets", component: "assets" },
              { type: "tab", name: "Timeline", component: "timeline" },
              { type: "tab", name: "AI Utilities", component: "utilities" },
              { type: "tab", name: "Camera", component: "camera" },
              { type: "tab", name: "RHI Stats", component: "rhistats" },
              { type: "tab", name: "Audio", component: "audio" },
              { type: "tab", name: "Plugins", component: "plugins" },
              { type: "tab", name: "Style", component: "style" },
              { type: "tab", name: "Render Queue", component: "renderqueue" },
              { type: "tab", name: "Physics", component: "physicsviz" },
              { type: "tab", name: "Post-FX", component: "postprocess" },
              { type: "tab", name: "Sequencer", component: "sequencer" },
              { type: "tab", name: "Animation", component: "animationeditor" },
              { type: "tab", name: "Material Graph", component: "materialgraph" },
              { type: "tab", name: "Scripts", component: "scriptviewer" },
              { type: "tab", name: "AI Chat", component: "aichat" },
              { type: "tab", name: "Particles", component: "particleeditor" },
              { type: "tab", name: "Prefabs", component: "prefabeditor" },
            ],
          },
        ],
      },
    ],
  },
};

function loadSavedLayout(): IJsonModel {
  try {
    const saved = localStorage.getItem(LAYOUT_STORAGE_KEY);
    if (saved) return JSON.parse(saved);
  } catch {
    // Corrupted — fall back to default.
  }
  return defaultLayout;
}

export function App() {
  const { t } = useI18n();
  const connected = useConnectionStore((s) => s.connected);
  const error = useConnectionStore((s) => s.error);
  const selectedEntity = useSceneStore((s) => s.selectedEntity);
  const settingsOpen = useEditorStore((s) => s.settingsOpen);
  const setSettingsOpen = useEditorStore((s) => s.setSettingsOpen);

  const modelRef = useRef<Model>(Model.fromJson(loadSavedLayout()));

  // Persist layout on every model change (debounced).
  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const handleModelChange = useCallback(() => {
    clearTimeout(saveTimerRef.current);
    saveTimerRef.current = setTimeout(() => {
      try {
        localStorage.setItem(LAYOUT_STORAGE_KEY, JSON.stringify(modelRef.current.toJson()));
      } catch {
        // Storage full — silently ignore.
      }
    }, 500);
  }, []);

  // Initialize RPC bridge + keyboard shortcuts
  useEffect(() => {
    const cleanupBridge = initRpcBridge();

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        window.guavaEngine.call("scene.save", {}).catch(() => {});
        return;
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) {
          window.guavaEngine.call("editor.redo", {}).catch(() => {});
        } else {
          window.guavaEngine.call("editor.undo", {}).catch(() => {});
        }
        return;
      }
      const { changeGizmoMode, selectedEntity: sel, refreshHierarchy: refresh } = useSceneStore.getState();
      switch (e.key.toLowerCase()) {
        case "q": changeGizmoMode("none"); break;
        case "w": changeGizmoMode("translate"); break;
        case "e": changeGizmoMode("rotate"); break;
        case "r": changeGizmoMode("scale"); break;
        case "delete":
        case "backspace":
          if (sel != null) {
            window.guavaEngine.call("scene.deleteEntity", { entityId: sel });
            useSceneStore.getState().setSelectedEntity(null);
            refresh();
          }
          break;
      }
    };
    window.addEventListener("keydown", handleKeyDown);

    return () => {
      cleanupBridge();
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, []);

  // Reset layout to default
  const handleResetLayout = useCallback(() => {
    localStorage.removeItem(LAYOUT_STORAGE_KEY);
    modelRef.current = Model.fromJson(defaultLayout);
    // Force re-render by toggling a trivial store field
    useEditorStore.getState().setSettingsOpen(useEditorStore.getState().settingsOpen);
  }, []);

  // Get list of panels not currently in the layout
  const getMissingPanels = useCallback(() => {
    const present = new Set<string>();
    modelRef.current.visitNodes((node) => {
      if (node.getType() === "tab") {
        const comp = (node as TabNode).getComponent();
        if (comp) present.add(comp);
      }
    });
    return ALL_PANELS.filter((p) => !present.has(p.id));
  }, []);

  // Add a panel back to the bottom tabset (or first available tabset)
  const handleAddPanel = useCallback((componentId: string) => {
    const panel = ALL_PANELS.find((p) => p.id === componentId);
    if (!panel) return;
    // Find a tabset to add to — prefer a non-viewport tabset
    let targetTabsetId: string | undefined;
    modelRef.current.visitNodes((node) => {
      if (node.getType() === "tabset" && node.getId() !== "viewport-tabset" && !targetTabsetId) {
        targetTabsetId = node.getId();
      }
    });
    if (!targetTabsetId) {
      // Fallback: use any tabset
      modelRef.current.visitNodes((node) => {
        if (node.getType() === "tabset" && !targetTabsetId) {
          targetTabsetId = node.getId();
        }
      });
    }
    if (targetTabsetId) {
      modelRef.current.doAction(
        Actions.addNode(
          { type: "tab", name: panel.name, component: panel.id },
          targetTabsetId,
          DockLocation.CENTER,
          -1,
          true,
        ),
      );
    }
  }, []);

  // ── Panel factory: maps component id → React element ──
  const factory = useCallback((node: TabNode) => {
    const component = node.getComponent();
    switch (component) {
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
      case "settings":        return <SettingsPanel />;
      default:
        return <div style={{ padding: 12, color: "#6c7086" }}>Unknown panel: {component}</div>;
    }
  }, []);

  if (error) {
    return (
      <div style={styles.errorContainer}>
        <h2>{t.app.connectionError}</h2>
        <p>{error}</p>
        <p style={{ opacity: 0.6, marginTop: 8 }}>
          {t.app.engineNotRunning}
        </p>
      </div>
    );
  }

  if (!connected) {
    return (
      <div style={styles.loadingContainer}>
        <div style={styles.spinner} />
        <p>{t.app.connectingToEngine}</p>
      </div>
    );
  }

  return (
    <div style={styles.root}>
      <Toolbar
        onResetLayout={handleResetLayout}
        onOpenSettings={() => setSettingsOpen(true)}
        getMissingPanels={getMissingPanels}
        onAddPanel={handleAddPanel}
      />
      <div style={styles.dockArea}>
        <Layout
          model={modelRef.current}
          factory={factory}
          onModelChange={handleModelChange}
          realtimeResize
        />
      </div>
      <ViewportStatus />
      {settingsOpen && (
        <div style={styles.modalBackdrop} onClick={() => setSettingsOpen(false)}>
          <div style={styles.modalPanel} onClick={(e) => e.stopPropagation()}>
            <div style={styles.modalHeader}>
              <span style={styles.modalTitle}>{t.app.settingsModalTitle}</span>
              <button style={styles.modalClose} onClick={() => setSettingsOpen(false)}>✕</button>
            </div>
            <div style={styles.modalBody}>
              <SettingsPanel />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    background: "#1e1e2e",
  },
  dockArea: {
    flex: 1,
    position: "relative",
    overflow: "hidden",
  },
  loadingContainer: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    height: "100vh",
    gap: 16,
    background: "#1e1e2e",
  },
  errorContainer: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    height: "100vh",
    gap: 8,
    color: "#f38ba8",
    background: "#1e1e2e",
  },
  spinner: {
    width: 24,
    height: 24,
    border: "3px solid #45475a",
    borderTop: "3px solid #89b4fa",
    borderRadius: "50%",
    animation: "spin 1s linear infinite",
  },
  modalBackdrop: {
    position: "fixed" as const,
    inset: 0,
    background: "rgba(0,0,0,0.5)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    zIndex: 9999,
  },
  modalPanel: {
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 8,
    width: 560,
    maxHeight: "80vh",
    display: "flex",
    flexDirection: "column" as const,
    boxShadow: "0 8px 32px rgba(0,0,0,0.6)",
  },
  modalHeader: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "10px 16px",
    borderBottom: "1px solid #313244",
  },
  modalTitle: {
    fontSize: 14,
    fontWeight: 600,
    color: "#cdd6f4",
  },
  modalClose: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 16,
    padding: "2px 6px",
    borderRadius: 4,
    lineHeight: 1,
  },
  modalBody: {
    flex: 1,
    overflow: "auto",
  },
};
