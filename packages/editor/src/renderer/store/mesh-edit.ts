import { create } from "zustand";
import { withBroadcastSync } from "./broadcast-sync";
import { rpc } from "../rpc";

export type MeshEditMode = "object" | "edit";
export type MeshSelectionMode = "vertex" | "edge" | "face";

export interface MeshEditState {
  active: boolean;
  mode: MeshEditMode;
  selectionMode: MeshSelectionMode;
  selectionCount: number;
  canEnterEditMode: boolean;
  entityId: number | null;

  // Actions — state update (typically from engine push)
  setMeshState: (state: {
    active: boolean;
    mode: MeshEditMode;
    selectionMode: MeshSelectionMode;
    selectionCount: number;
    canEnterEditMode?: boolean;
    entityId: number | null;
  }) => void;

  // RPC actions — send commands to engine
  enterEditMode: (entityId?: number) => Promise<boolean>;
  exitEditMode: () => Promise<void>;
  setSelectionMode: (mode: MeshSelectionMode) => Promise<void>;
  toggleEditMode: (entityId?: number) => Promise<void>;

  // Mesh operations
  extrude: () => Promise<boolean>;
  inset: () => Promise<boolean>;
  bevel: () => Promise<boolean>;
  loopCut: () => Promise<boolean>;
  merge: () => Promise<boolean>;
  deleteMesh: () => Promise<boolean>;
  duplicate: () => Promise<boolean>;
  separate: () => Promise<boolean>;
  recalcNormals: () => Promise<boolean>;
  pivotToSelection: () => Promise<boolean>;

  // Fetch current state from engine
  refreshState: () => Promise<void>;
}

export const useMeshEditStore = create<MeshEditState>(
  withBroadcastSync(
    {
      name: "mesh-edit",
      syncKeys: ["active", "mode", "selectionMode", "selectionCount", "entityId"],
    },
    (set, get) => ({
      active: false,
      mode: "object",
      selectionMode: "face",
      selectionCount: 0,
      canEnterEditMode: false,
      entityId: null,

      setMeshState: (state) =>
        set({
          active: state.active,
          mode: state.mode,
          selectionMode: state.selectionMode,
          selectionCount: state.selectionCount,
          canEnterEditMode: state.canEnterEditMode ?? false,
          entityId: state.entityId,
        }),

      enterEditMode: async (entityId) => {
        try {
          const eid = entityId ?? get().entityId;
          const result = await rpc("mesh.enterEditMode", { entityId: eid ?? undefined });
          return result.success;
        } catch (e) {
          console.error("mesh.enterEditMode failed:", e);
          return false;
        }
      },

      exitEditMode: async () => {
        try {
          await rpc("mesh.exitEditMode", {});
        } catch (e) {
          console.error("mesh.exitEditMode failed:", e);
        }
      },

      setSelectionMode: async (mode) => {
        try {
          await rpc("mesh.setSelectionMode", { mode });
        } catch (e) {
          console.error("mesh.setSelectionMode failed:", e);
        }
      },

      toggleEditMode: async (entityId) => {
        const { active } = get();
        if (active) {
          await get().exitEditMode();
        } else {
          await get().enterEditMode(entityId);
        }
      },

      extrude: async () => {
        try {
          return (await rpc("mesh.extrude", {})).success;
        } catch {
          return false;
        }
      },
      inset: async () => {
        try {
          return (await rpc("mesh.inset", {})).success;
        } catch {
          return false;
        }
      },
      bevel: async () => {
        try {
          return (await rpc("mesh.bevel", {})).success;
        } catch {
          return false;
        }
      },
      loopCut: async () => {
        try {
          return (await rpc("mesh.loopCut", {})).success;
        } catch {
          return false;
        }
      },
      merge: async () => {
        try {
          return (await rpc("mesh.merge", {})).success;
        } catch {
          return false;
        }
      },
      deleteMesh: async () => {
        try {
          return (await rpc("mesh.delete", {})).success;
        } catch {
          return false;
        }
      },
      duplicate: async () => {
        try {
          return (await rpc("mesh.duplicate", {})).success;
        } catch {
          return false;
        }
      },
      separate: async () => {
        try {
          return (await rpc("mesh.separate", {})).success;
        } catch {
          return false;
        }
      },
      recalcNormals: async () => {
        try {
          return (await rpc("mesh.recalcNormals", {})).success;
        } catch {
          return false;
        }
      },
      pivotToSelection: async () => {
        try {
          return (await rpc("mesh.pivotToSelection", {})).success;
        } catch {
          return false;
        }
      },

      refreshState: async () => {
        try {
          const result = await rpc("mesh.getState", {});
          set({
            active: result.active,
            mode: result.mode as MeshEditMode,
            selectionMode: result.selectionMode as MeshSelectionMode,
            selectionCount: result.selectionCount,
            canEnterEditMode: result.canEnterEditMode,
            entityId: result.entityId ?? null,
          });
        } catch (e) {
          console.error("mesh.getState failed:", e);
        }
      },
    }),
  ),
);
