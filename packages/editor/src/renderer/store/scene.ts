import { create } from "zustand";
import type { EntityNode, GizmoMode } from "../../shared/rpc-types";
import { withBroadcastSync } from "./broadcast-sync";
import { engine } from "../engine-client";

export type PlaybackState = "stopped" | "playing" | "paused";

export interface SceneState {
  hierarchy: EntityNode[];
  selectedEntity: number | null;
  gizmoMode: GizmoMode;
  /** Current engine scene revision (incremented on every change) */
  sceneRevision: number;
  /** Scene revision at last successful save */
  savedRevision: number;
  /** Current playback state */
  playbackState: PlaybackState;

  setHierarchy: (roots: EntityNode[]) => void;
  setSelectedEntity: (entityId: number | null) => void;
  setGizmoMode: (mode: GizmoMode) => void;
  /** Update the current scene revision (called from on:scene.changed) */
  setSceneRevision: (rev: number) => void;
  /** Mark a specific revision as saved (or current if omitted) */
  markSaved: (revision?: number) => void;
  setPlaybackState: (state: PlaybackState) => void;

  refreshHierarchy: () => Promise<void>;
  selectEntity: (entityId: number) => Promise<void>;
  changeGizmoMode: (mode: GizmoMode) => void;
}

export const useSceneStore = create<SceneState>(
  withBroadcastSync(
    { name: "scene", syncKeys: ["hierarchy", "selectedEntity", "gizmoMode", "sceneRevision", "savedRevision", "playbackState"] },
    (set, get) => ({
      hierarchy: [],
      selectedEntity: null,
      gizmoMode: "none",
      sceneRevision: 0,
      savedRevision: 0,
      playbackState: "stopped" as PlaybackState,

      setHierarchy: (roots) => set({ hierarchy: roots }),
      setSelectedEntity: (entityId) => set({ selectedEntity: entityId }),
      setGizmoMode: (mode) => set({ gizmoMode: mode }),
      setSceneRevision: (rev) => set({ sceneRevision: rev }),
      markSaved: (revision?: number) => set({ savedRevision: revision ?? get().sceneRevision }),
      setPlaybackState: (state) => set({ playbackState: state }),

      refreshHierarchy: async () => {
        try {
          const result = await engine.call("scene.getHierarchy", {});
          set({ hierarchy: result.roots });
        } catch (e) {
          console.error("Failed to fetch hierarchy:", e);
        }
      },

      selectEntity: async (entityId) => {
        set({ selectedEntity: entityId });
        try {
          await engine.call("editor.setSelection", { entityIds: [entityId] });
        } catch (e) {
          console.error("Failed to set selection:", e);
        }
      },

      changeGizmoMode: (mode) => {
        set({ gizmoMode: mode });
        engine.call("viewport.setGizmoMode", { mode }).catch(() => {});
      },
    }),
  ),
);
