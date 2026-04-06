import { create } from "zustand";
import type { EntityNode, GizmoMode } from "../../shared/rpc-types";
import { withBroadcastSync } from "./broadcast-sync";

export interface SceneState {
  hierarchy: EntityNode[];
  selectedEntity: number | null;
  gizmoMode: GizmoMode;
  /** Current engine scene revision (incremented on every change) */
  sceneRevision: number;
  /** Scene revision at last successful save */
  savedRevision: number;

  setHierarchy: (roots: EntityNode[]) => void;
  setSelectedEntity: (entityId: number | null) => void;
  setGizmoMode: (mode: GizmoMode) => void;
  /** Update the current scene revision (called from on:scene.changed) */
  setSceneRevision: (rev: number) => void;
  /** Mark the current revision as saved */
  markSaved: () => void;

  refreshHierarchy: () => Promise<void>;
  selectEntity: (entityId: number) => Promise<void>;
  changeGizmoMode: (mode: GizmoMode) => void;
}

export const useSceneStore = create<SceneState>(
  withBroadcastSync(
    { name: "scene", syncKeys: ["hierarchy", "selectedEntity", "gizmoMode", "sceneRevision", "savedRevision"] },
    (set, get) => ({
      hierarchy: [],
      selectedEntity: null,
      gizmoMode: "none",
      sceneRevision: 0,
      savedRevision: 0,

      setHierarchy: (roots) => set({ hierarchy: roots }),
      setSelectedEntity: (entityId) => set({ selectedEntity: entityId }),
      setGizmoMode: (mode) => set({ gizmoMode: mode }),
      setSceneRevision: (rev) => set({ sceneRevision: rev }),
      markSaved: () => set({ savedRevision: get().sceneRevision }),

      refreshHierarchy: async () => {
        try {
          const result = await window.guavaEngine.call("scene.getHierarchy", {});
          set({ hierarchy: result.roots });
        } catch (e) {
          console.error("Failed to fetch hierarchy:", e);
        }
      },

      selectEntity: async (entityId) => {
        set({ selectedEntity: entityId });
        try {
          await window.guavaEngine.call("editor.setSelection", { entityIds: [entityId] });
        } catch (e) {
          console.error("Failed to set selection:", e);
        }
      },

      changeGizmoMode: (mode) => {
        set({ gizmoMode: mode });
        window.guavaEngine.call("viewport.setGizmoMode", { mode }).catch(() => {});
      },
    }),
  ),
);
