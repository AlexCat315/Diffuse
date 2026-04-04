import { create } from "zustand";
import type { EntityNode, GizmoMode } from "../../shared/rpc-types";

export interface SceneState {
  hierarchy: EntityNode[];
  selectedEntity: number | null;
  gizmoMode: GizmoMode;

  setHierarchy: (roots: EntityNode[]) => void;
  setSelectedEntity: (entityId: number | null) => void;
  setGizmoMode: (mode: GizmoMode) => void;

  refreshHierarchy: () => Promise<void>;
  selectEntity: (entityId: number) => Promise<void>;
  changeGizmoMode: (mode: GizmoMode) => void;
}

export const useSceneStore = create<SceneState>((set, get) => ({
  hierarchy: [],
  selectedEntity: null,
  gizmoMode: "translate",

  setHierarchy: (roots) => set({ hierarchy: roots }),
  setSelectedEntity: (entityId) => set({ selectedEntity: entityId }),
  setGizmoMode: (mode) => set({ gizmoMode: mode }),

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
}));
