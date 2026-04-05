import type { LogEntry } from "../../shared/rpc-types";
import { useConnectionStore } from "./connection";
import { useSceneStore } from "./scene";
import { useConsoleStore } from "./console";
import { useEntityCacheStore } from "./entity-cache";
import { useMeshEditStore } from "./mesh-edit";
import type { MeshEditMode, MeshSelectionMode } from "./mesh-edit";

/**
 * Initialize the bridge between engine IPC events and Zustand stores.
 * Call once at app startup. Returns a cleanup function.
 */
export function initRpcBridge(): () => void {
  const cleanupConnected = window.guavaEngine.onConnected(() => {
    useConnectionStore.getState().setConnected(true);
    useSceneStore.getState().refreshHierarchy();
    useMeshEditStore.getState().refreshState();
  });

  const cleanupError = window.guavaEngine.onError((err) => {
    useConnectionStore.getState().setError(err);
  });

  const cleanupEvents = window.guavaEngine.onEvent((event, data) => {
    switch (event) {
      case "on:scene.changed": {
        const d = data as { revision: number; entityIds: number[] };
        useSceneStore.getState().refreshHierarchy();
        useEntityCacheStore.getState().invalidate(d.entityIds);
        break;
      }
      case "on:selection.changed": {
        const d = data as { entityIds: number[] };
        useSceneStore.getState().setSelectedEntity(d.entityIds[0] ?? null);
        break;
      }
      case "on:console.log":
        useConsoleStore.getState().appendLog(data as LogEntry);
        break;
      case "on:console.logs": {
        const d = data as { entries: LogEntry[] };
        const store = useConsoleStore.getState();
        for (const entry of d.entries) {
          store.appendLog(entry);
        }
        break;
      }
      case "on:mesh.stateChanged": {
        const d = data as {
          active: boolean;
          mode: MeshEditMode;
          selectionMode: MeshSelectionMode;
          selectionCount: number;
          canEnterEditMode: boolean;
          entityId: number | null;
        };
        useMeshEditStore.getState().setMeshState(d);
        break;
      }
    }
  });

  // Check if engine is already connected on startup
  window.guavaEngine.getStatus().then((status) => {
    if (status.rpcConnected) {
      useConnectionStore.getState().setConnected(true);
      useSceneStore.getState().refreshHierarchy();
      useMeshEditStore.getState().refreshState();
    }
  });

  return () => {
    cleanupConnected();
    cleanupError();
    cleanupEvents();
  };
}
