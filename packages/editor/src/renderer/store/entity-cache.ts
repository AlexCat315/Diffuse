import { create } from "zustand";
import type { Transform, ComponentInfo } from "../../shared/rpc-types";
import { engine } from "../engine-client";

interface EntityData {
  transform: Transform | null;
  components: ComponentInfo[];
  materialState: unknown | null;
  /** Timestamp of last fetch — used for staleness checks */
  fetchedAt: number;
}

export interface EntityCacheState {
  cache: Map<number, EntityData>;

  /**
   * Fetch entity data (transform + components) from engine.
   * Returns cached data if fresh (< 200ms old) unless `force` is true.
   */
  fetchEntity: (entityId: number, force?: boolean) => Promise<EntityData | null>;

  /**
   * Fetch material state for an entity.
   * Merges into existing cache entry.
   */
  fetchMaterial: (entityId: number) => Promise<unknown | null>;

  /** Invalidate cache for specific entity IDs (e.g. on scene.changed) */
  invalidate: (entityIds?: number[]) => void;

  /** Get cached data without fetching */
  getCached: (entityId: number) => EntityData | undefined;
}

const FRESHNESS_MS = 200;

export const useEntityCacheStore = create<EntityCacheState>((set, get) => ({
  cache: new Map(),

  fetchEntity: async (entityId, force = false) => {
    const existing = get().cache.get(entityId);
    if (!force && existing && Date.now() - existing.fetchedAt < FRESHNESS_MS) {
      return existing;
    }
    try {
      const [t, c] = await Promise.all([
        engine.call("entity.getTransform", { entityId }),
        engine.call("entity.getComponents", { entityId }),
      ]);
      const data: EntityData = {
        transform: t,
        components: c.components,
        materialState: existing?.materialState ?? null,
        fetchedAt: Date.now(),
      };
      set((state) => {
        const next = new Map(state.cache);
        next.set(entityId, data);
        return { cache: next };
      });
      return data;
    } catch {
      return null;
    }
  },

  fetchMaterial: async (entityId) => {
    try {
      const mat = await engine.call("material.getState", { entityId });
      set((state) => {
        const next = new Map(state.cache);
        const existing = next.get(entityId);
        next.set(entityId, {
          transform: existing?.transform ?? null,
          components: existing?.components ?? [],
          materialState: mat,
          fetchedAt: existing?.fetchedAt ?? Date.now(),
        });
        return { cache: next };
      });
      return mat;
    } catch {
      return null;
    }
  },

  invalidate: (entityIds) => {
    if (!entityIds) {
      set({ cache: new Map() });
      return;
    }
    set((state) => {
      const next = new Map(state.cache);
      for (const id of entityIds) {
        next.delete(id);
      }
      return { cache: next };
    });
  },

  getCached: (entityId) => get().cache.get(entityId),
}));
