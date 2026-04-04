import React, { useEffect, useState, useCallback, useRef } from "react";
import { Layout, Model, Actions, type IJsonModel, type TabNode } from "flexlayout-react";
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
import { SettingsPanel } from "./panels/Settings";
import { useI18n } from "./i18n";
import type { EntityNode, LogEntry, GizmoMode } from "../shared/rpc-types";

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}

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
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [hierarchy, setHierarchy] = useState<EntityNode[]>([]);
  const [selectedEntity, setSelectedEntity] = useState<number | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [gizmoMode, setGizmoMode] = useState<GizmoMode>("translate");
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

  useEffect(() => {
    const cleanupConnected = window.guavaEngine.onConnected(() => {
      setConnected(true);
      refreshHierarchy();
    });

    const cleanupError = window.guavaEngine.onError((err) => {
      setError(err);
    });

    const cleanupEvents = window.guavaEngine.onEvent((event, data) => {
      switch (event) {
        case "on:scene.changed":
          refreshHierarchy();
          break;
        case "on:selection.changed": {
          const d = data as { entityIds: number[] };
          setSelectedEntity(d.entityIds[0] ?? null);
          break;
        }
        case "on:console.log":
          setLogs((prev) => [...prev.slice(-499), data as LogEntry]);
          break;
      }
    });

    // Check if already connected
    window.guavaEngine.getStatus().then((status) => {
      if (status.rpcConnected) {
        setConnected(true);
        refreshHierarchy();
      }
    });

    // Keyboard shortcuts
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      // Ctrl/Cmd+S → Save scene
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        window.guavaEngine.call("scene.save", {}).catch(() => {});
        return;
      }
      // Ctrl/Cmd+Z → Undo, Ctrl/Cmd+Shift+Z → Redo
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) {
          window.guavaEngine.call("editor.redo", {}).catch(() => {});
        } else {
          window.guavaEngine.call("editor.undo", {}).catch(() => {});
        }
        return;
      }
      switch (e.key.toLowerCase()) {
        case "w": setGizmoMode("translate"); handleGizmoChange("translate"); break;
        case "e": setGizmoMode("rotate"); handleGizmoChange("rotate"); break;
        case "r": setGizmoMode("scale"); handleGizmoChange("scale"); break;
        case "delete":
        case "backspace":
          if (selectedEntity != null) {
            window.guavaEngine.call("scene.deleteEntity", { entityId: selectedEntity });
            setSelectedEntity(null);
            refreshHierarchy();
          }
          break;
      }
    };
    window.addEventListener("keydown", handleKeyDown);

    return () => {
      cleanupConnected();
      cleanupError();
      cleanupEvents();
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, []);

  const refreshHierarchy = useCallback(async () => {
    try {
      const result = await window.guavaEngine.call("scene.getHierarchy", {});
      setHierarchy(result.roots);
    } catch (e) {
      console.error("Failed to fetch hierarchy:", e);
    }
  }, []);

  const handleSelectEntity = useCallback(async (entityId: number) => {
    setSelectedEntity(entityId);
    try {
      await window.guavaEngine.call("editor.setSelection", {
        entityIds: [entityId],
      });
    } catch (e) {
      console.error("Failed to set selection:", e);
    }
  }, []);

  const handleGizmoChange = useCallback((mode: GizmoMode) => {
    setGizmoMode(mode);
    window.guavaEngine.call("viewport.setGizmoMode", { mode }).catch(() => {});
  }, []);

  const handleClearLogs = useCallback(() => {
    setLogs([]);
    window.guavaEngine.call("console.clear", {}).catch(() => {});
  }, []);

  // Reset layout to default
  const handleResetLayout = useCallback(() => {
    localStorage.removeItem(LAYOUT_STORAGE_KEY);
    modelRef.current = Model.fromJson(defaultLayout);
    // Force re-render
    setLogs((prev) => [...prev]);
  }, []);

  // ── Panel factory: maps component id → React element ──
  const factory = useCallback((node: TabNode) => {
    const component = node.getComponent();
    switch (component) {
      case "viewport":
        return <Viewport connected={connected} />;
      case "hierarchy":
        return (
          <SceneHierarchy
            roots={hierarchy}
            selectedId={selectedEntity}
            onSelect={handleSelectEntity}
            onRefresh={refreshHierarchy}
          />
        );
      case "inspector":
        return <Inspector entityId={selectedEntity} />;
      case "material":
        return <MaterialEditor entityId={selectedEntity} />;
      case "rendersettings":
        return <RenderSettingsPanel connected={connected} />;
      case "console":
        return <Console logs={logs} onClear={handleClearLogs} />;
      case "assets":
        return <AssetBrowser connected={connected} />;
      case "timeline":
        return <CommandTimeline connected={connected} />;
      case "utilities":
        return <EditorUtilities connected={connected} />;
      case "camera":
        return <CameraBookmarks connected={connected} />;
      case "rhistats":
        return <RhiStats connected={connected} />;
      case "audio":
        return <AudioMixer connected={connected} />;
      case "plugins":
        return <PluginManager connected={connected} />;
      case "style":
        return <StyleInspector connected={connected} />;
      case "placeactors":
        return <PlaceActors connected={connected} />;
      case "renderqueue":
        return <RenderQueue connected={connected} />;
      case "physicsviz":
        return <PhysicsVisualization connected={connected} />;
      case "postprocess":
        return <PostProcessEditor connected={connected} />;
      case "sequencer":
        return <SequencerPanel connected={connected} />;
      case "settings":
        return <SettingsPanel connected={connected} />;
      default:
        return <div style={{ padding: 12, color: "#6c7086" }}>Unknown panel: {component}</div>;
    }
  }, [connected, hierarchy, selectedEntity, logs, handleSelectEntity, refreshHierarchy, handleClearLogs]);

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
        gizmoMode={gizmoMode}
        onGizmoModeChange={handleGizmoChange}
        onRefreshHierarchy={refreshHierarchy}
        onResetLayout={handleResetLayout}
        onOpenSettings={() => setSettingsOpen(true)}
      />
      <div style={styles.dockArea}>
        <Layout
          model={modelRef.current}
          factory={factory}
          onModelChange={handleModelChange}
          realtimeResize
        />
      </div>
      <ViewportStatus connected={connected} />
      {settingsOpen && (
        <div style={styles.modalBackdrop} onClick={() => setSettingsOpen(false)}>
          <div style={styles.modalPanel} onClick={(e) => e.stopPropagation()}>
            <div style={styles.modalHeader}>
              <span style={styles.modalTitle}>Settings</span>
              <button style={styles.modalClose} onClick={() => setSettingsOpen(false)}>✕</button>
            </div>
            <div style={styles.modalBody}>
              <SettingsPanel connected={connected} />
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
