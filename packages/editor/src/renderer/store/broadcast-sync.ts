import type { StateCreator } from "zustand";

/**
 * Zustand middleware that syncs store state across Electron windows
 * using the BroadcastChannel API.
 *
 * Only serializable state fields (specified via `syncKeys`) are synced.
 * Actions/functions are never broadcast.
 */

const CHANNEL_PREFIX = "guava-store-sync:";

interface SyncOptions<T> {
  /** Unique channel name for this store */
  name: string;
  /** State keys to sync (only serializable data, not functions) */
  syncKeys: (keyof T & string)[];
}

export function withBroadcastSync<T extends object>(
  options: SyncOptions<T>,
  creator: StateCreator<T>,
): StateCreator<T> {
  return (set, get, api) => {
    const channel = new BroadcastChannel(CHANNEL_PREFIX + options.name);
    let isSyncing = false; // prevent echo loops

    // Listen for updates from other windows
    channel.onmessage = (event: MessageEvent) => {
      const patch = event.data as Partial<T>;
      if (!patch || typeof patch !== "object") return;
      // Apply the patch without triggering our own broadcast
      isSyncing = true;
      set(patch);
      isSyncing = false;
    };

    // Wrap set to broadcast changes
    const syncSet: typeof set = (partial, replace?) => {
      (set as Function)(partial, replace);
      if (isSyncing) return; // don't re-broadcast received changes

      // Extract only the sync keys from the current state
      const state = get();
      const patch: Record<string, unknown> = {};
      let hasPatch = false;

      // Resolve the partial (could be a function)
      const resolved = typeof partial === "function"
        ? (partial as (s: T) => Partial<T>)(state)
        : partial;

      for (const key of options.syncKeys) {
        if (key in (resolved as object)) {
          patch[key] = (resolved as Record<string, unknown>)[key];
          hasPatch = true;
        }
      }

      if (hasPatch) {
        channel.postMessage(patch);
      }
    };

    // Clean up channel when the window unloads
    if (typeof window !== "undefined") {
      window.addEventListener("beforeunload", () => channel.close());
    }

    return creator(syncSet, get, api);
  };
}
