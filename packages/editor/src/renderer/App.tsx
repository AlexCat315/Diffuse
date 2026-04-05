import React, { useEffect, useCallback, useRef, useState } from "react";
import { Layout, Model, Actions, DockLocation, type IJsonModel, type TabNode, type TabSetNode, type ITabSetRenderValues, type ITabRenderValues } from "flexlayout-react";
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
const LAYOUT_STORAGE_KEY = "guava-editor-layout-v3";
const BOTTOM_TABSET_ID = "bottom-tabset";
const DEFAULT_MIN_HEIGHT = 100;

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
    rootOrientationVertical: true,
  },
  borders: [],
  layout: {
    type: "row",
    weight: 100,
    children: [
      {
        // Top area: Hierarchy | Viewport | Inspector (horizontal row)
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
        // Bottom: Console, Assets, Timeline, etc.
        type: "tabset",
        weight: 30,
        id: BOTTOM_TABSET_ID,
        enableMaximize: false,
        minHeight: DEFAULT_MIN_HEIGHT,
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

  // ── Bottom panel collapse/expand ──
  const [bottomCollapsed, setBottomCollapsed] = useState(false);
  const bottomCollapsedRef = useRef(false);

  const toggleBottomPanel = useCallback(() => {
    const model = modelRef.current;
    const next = !bottomCollapsedRef.current;
    bottomCollapsedRef.current = next;
    setBottomCollapsed(next);
    if (next) {
      // Collapse: set content area height to 0; flexlayout adds tab strip height on top
      model.doAction(Actions.updateNodeAttributes(BOTTOM_TABSET_ID, { maxHeight: 0, minHeight: 0 }));
    } else {
      // Expand: restore default constraints
      model.doAction(Actions.updateNodeAttributes(BOTTOM_TABSET_ID, { maxHeight: 99999, minHeight: DEFAULT_MIN_HEIGHT }));
    }
  }, []);

  const toggleBottomPanelRef = useRef(toggleBottomPanel);
  toggleBottomPanelRef.current = toggleBottomPanel;

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
      // Cmd/Ctrl+J: toggle bottom panel
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "j") {
        e.preventDefault();
        toggleBottomPanelRef.current();
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

  // Listen for popout windows being closed → re-add panels to layout
  useEffect(() => {
    const cleanup = window.guavaEngine.onPopoutClosed((panels: string[], originInfo?: unknown, bounds?: { x: number; y: number; width: number; height: number }) => {
      const origin = originInfo as { tabsetId?: string; tabIndex?: number; tabName?: string } | undefined;

      // Persist window bounds for each panel so next popout opens at the same size/position
      if (bounds) {
        for (const panelId of panels) {
          try {
            localStorage.setItem(`popout-bounds-${panelId}`, JSON.stringify(bounds));
          } catch { /* ignore */ }
        }
      }

      for (const panelId of panels) {
        const panel = ALL_PANELS.find((p) => p.id === panelId);
        if (!panel) continue;
        // Check if panel already exists in layout
        let exists = false;
        modelRef.current.visitNodes((node) => {
          if (node.getType() === "tab" && (node as TabNode).getComponent() === panelId) {
            exists = true;
          }
        });
        if (exists) continue;

        // Determine target tabset: use original position if the tabset still exists
        let targetTabsetId = BOTTOM_TABSET_ID;
        const tabIndex = origin?.tabIndex ?? -1;
        if (origin?.tabsetId) {
          // Verify the tabset still exists
          let tabsetExists = false;
          modelRef.current.visitNodes((node) => {
            if (node.getId() === origin.tabsetId) tabsetExists = true;
          });
          if (tabsetExists) {
            targetTabsetId = origin.tabsetId;
          }
        }

        modelRef.current.doAction(
          Actions.addNode(
            { type: "tab", name: origin?.tabName ?? panel.name, component: panel.id },
            targetTabsetId,
            DockLocation.CENTER,
            tabIndex,
            false,
          ),
        );
      }
    });
    return cleanup;
  }, []);

  // Reset layout to default
  const handleResetLayout = useCallback(() => {
    localStorage.removeItem(LAYOUT_STORAGE_KEY);
    modelRef.current = Model.fromJson(defaultLayout);
    setBottomCollapsed(false);
    bottomCollapsedRef.current = false;
    // Force re-render by toggling a trivial store field
    useEditorStore.getState().setSettingsOpen(useEditorStore.getState().settingsOpen);
  }, []);

  // Pop out a tab into a separate window
  const handlePopout = useCallback((node: TabNode) => {
    const componentId = node.getComponent();
    if (!componentId || componentId === "viewport") return; // viewport stays in main window

    // Record origin: parent tabset ID and tab index within it
    const parent = node.getParent();
    const originInfo = {
      tabsetId: parent?.getId() ?? BOTTOM_TABSET_ID,
      tabIndex: parent ? Array.from({ length: (parent as TabSetNode).getChildren().length }, (_, i) => i)
        .find((i) => (parent as TabSetNode).getChildren()[i].getId() === node.getId()) ?? -1 : -1,
      tabName: node.getName(),
    };

    // Snapshot store state for the popout window
    const initialState = {
      consoleLogs: useConsoleStore.getState().logs,
      sceneHierarchy: useSceneStore.getState().hierarchy,
      selectedEntity: useSceneStore.getState().selectedEntity,
      gizmoMode: useSceneStore.getState().gizmoMode,
    };

    // Load saved window bounds for this panel (if any)
    let savedBounds: { width?: number; height?: number; x?: number; y?: number } | undefined;
    try {
      const raw = localStorage.getItem(`popout-bounds-${componentId}`);
      if (raw) savedBounds = JSON.parse(raw);
    } catch { /* ignore */ }

    // Remove the tab from layout
    modelRef.current.doAction(Actions.deleteTab(node.getId()));
    // Open in new window with state + origin info + saved bounds
    window.guavaEngine.popoutPanel([componentId], initialState, originInfo, savedBounds);
  }, []);

  // ── onRenderTab: add popout button to each tab ──
  const handleRenderTab = useCallback(
    (node: TabNode, renderValues: ITabRenderValues) => {
      const componentId = node.getComponent();
      // Don't show popout button for viewport (needs native surface)
      if (componentId === "viewport") return;
      renderValues.buttons.push(
        <button
          key="popout-btn"
          className="guava-popout-btn"
          title="在新窗口中打开"
          onPointerDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            handlePopout(node);
          }}
        >
          <svg width="10" height="10" viewBox="0 0 10 10">
            <path d="M1 3.5V8.5H6" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
            <path d="M4 1.5H8.5V6" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
            <path d="M4 6L8.5 1.5" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>,
      );
    },
    [handlePopout],
  );

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

  // ── onRenderTabSet: add collapse button to bottom tabset ──
  const handleRenderTabSet = useCallback(
    (tabSetNode: TabSetNode | any, renderValues: ITabSetRenderValues) => {
      if (tabSetNode.getId() === BOTTOM_TABSET_ID) {
        renderValues.buttons.unshift(
          <button
            key="collapse-btn"
            className="guava-collapse-btn"
            title={bottomCollapsedRef.current ? "展开底部面板 (⌘J)" : "折叠底部面板 (⌘J)"}
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              toggleBottomPanelRef.current();
            }}
          >
            <svg width="12" height="12" viewBox="0 0 12 12">
              {bottomCollapsedRef.current
                ? <path d="M2 8L6 4l4 4" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
                : <path d="M2 4l4 4 4-4" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
              }
            </svg>
          </button>
        );
      }
    },
    [],
  );

  // ── onAction: intercept maximize-toggle on bottom tabset → collapse instead ──
  const handleAction = useCallback(
    (action: any) => {
      if (action.type === Actions.MAXIMIZE_TOGGLE) {
        const nodeId = action.data?.node;
        if (nodeId === BOTTOM_TABSET_ID) {
          toggleBottomPanelRef.current();
          return undefined; // swallow the maximize action
        }
      }
      return action;
    },
    [],
  );

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
      />
      <div style={styles.dockArea}>
        <Layout
          model={modelRef.current}
          factory={factory}
          onModelChange={handleModelChange}
          onRenderTabSet={handleRenderTabSet}
          onRenderTab={handleRenderTab}
          onAction={handleAction}
          realtimeResize
        />
      </div>
      <ViewportStatus />
      {settingsOpen && (
        <DraggableSettingsModal onClose={() => setSettingsOpen(false)} title={t.app.settingsModalTitle} />
      )}
    </div>
  );
}

// ── Draggable Settings Modal ─────────────────────────────────────

function DraggableSettingsModal({ onClose, title }: { onClose: () => void; title: string }) {
  const panelRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const dragging = useRef(false);
  const dragOffset = useRef({ x: 0, y: 0 });

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if ((e.target as HTMLElement).tagName === "BUTTON") return;
    dragging.current = true;
    const panel = panelRef.current;
    if (!panel) return;
    const rect = panel.getBoundingClientRect();
    dragOffset.current = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    e.preventDefault();

    const onMove = (ev: MouseEvent) => {
      if (!dragging.current) return;
      setPos({ x: ev.clientX - dragOffset.current.x, y: ev.clientY - dragOffset.current.y });
    };
    const onUp = () => {
      dragging.current = false;
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }, []);

  const panelStyle: React.CSSProperties = pos
    ? { ...styles.modalPanel, left: pos.x, top: pos.y }
    : styles.modalPanel;

  return (
    <div style={styles.modalBackdrop} onClick={onClose}>
      <div ref={panelRef} style={panelStyle} onClick={(e) => e.stopPropagation()}>
        <div style={styles.modalHeader} onMouseDown={onMouseDown}>
          <span style={styles.modalTitle}>{title}</span>
          <button style={styles.modalClose} onClick={onClose}>✕</button>
        </div>
        <div style={styles.modalBody}>
          <SettingsPanel />
        </div>
      </div>
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
    background: "rgba(0,0,0,0.35)",
    zIndex: 9999,
  },
  modalPanel: {
    position: "absolute" as const,
    left: "calc(50% - 280px)",
    top: "calc(50% - 35vh)",
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 8,
    width: 560,
    height: "70vh",
    minWidth: 400,
    minHeight: 300,
    maxWidth: "95vw",
    maxHeight: "95vh",
    resize: "both" as const,
    display: "flex",
    flexDirection: "column" as const,
    boxShadow: "0 8px 32px rgba(0,0,0,0.6)",
    overflow: "hidden",
  },
  modalHeader: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "10px 16px",
    borderBottom: "1px solid #313244",
    cursor: "grab",
    userSelect: "none" as const,
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
    overflow: "hidden",
    minHeight: 0,
  },
};
