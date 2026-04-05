import type { StateCreator } from "zustand";

/**
 * Zustand middleware that syncs store state across Electron windows
 * using the BroadcastChannel API.
 *
 * Only serializable state fields (specified via `syncKeys`) are synced.
 * Actions/functions are never broadcast.
 *
 * New windows automatically request full state from existing windows
 * on init (sync-request / sync-response handshake).
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
    let syncedFromRemote = false;

    // Listen for updates from other windows
    channel.onmessage = (event: MessageEvent) => {
      const msg = event.data;
      if (!msg || typeof msg !== "object") return;

      // Another window requesting our full state
      if (msg.type === "sync-request") {
        const state = get();
        const snapshot: Record<string, unknown> = {};
        for (const key of options.syncKeys) {
          snapshot[key] = (state as Record<string, unknown>)[key];
        }
        channel.postMessage({ type: "sync-response", data: snapshot });
        return;
      }

      // Response to our sync request — apply full state (first response only)
      if (msg.type === "sync-response" && !syncedFromRemote) {
        syncedFromRemote = true;
        const remote = msg.data as Partial<T>;
        if (!remote || typeof remote !== "object") return;
        isSyncing = true;
        set(remote);
        isSyncing = false;
        return;
      }

      // Regular per-key patch
      if (msg.type === undefined) {
        const patch = msg as Partial<T>;
        isSyncing = true;
        set(patch);
        isSyncing = false;
      }
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

    // Request existing state from other windows on init
    setTimeout(() => channel.postMessage({ type: "sync-request" }), 0);

    return creator(syncSet, get, api);
  };
}
