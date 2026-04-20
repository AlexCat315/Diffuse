/**
 * Cross-window synced state store.
 *
 * Every value set here is automatically synced to other Electron windows
 * (popouts) via BroadcastChannel.  Use `useSyncedState()` as a drop-in
 * replacement for `useState` whenever state needs to be shared across windows.
 *
 * Guidelines:
 *   • Config / preference / shared state → useSyncedState  (syncs across windows)
 *   • Ephemeral UI state (hover, loading) → useLocalState   (local only)
 */

import { useCallback, useRef } from "react";
import { create } from "zustand";

// ── Store ──────────────────────────────────────────────────────

const CHANNEL_NAME = "guava-synced-state";

interface SyncedStateStore {
  /** namespace → key → value */
  settings: Record<string, Record<string, unknown>>;
  /** @internal — use useSyncedState() instead */
  _set: (namespace: string, key: string, value: unknown) => void;
}

let channel: BroadcastChannel | null = null;
let isSyncing = false;

function getChannel(): BroadcastChannel {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }
  return channel;
}

function safeSend(data: unknown): void {
  try {
    getChannel().postMessage(data);
  } catch {
    // Channel was closed (e.g. window unload race) — recreate and retry once
    channel = null;
    try {
      getChannel().postMessage(data);
    } catch {
      // Still failing — give up silently
    }
  }
}

export const useSyncedStateStore = create<SyncedStateStore>((set) => {
  let syncedFromRemote = false;

  // Listen for updates from other windows
  getChannel().onmessage = (event: MessageEvent) => {
    const msg = event.data;
    if (!msg || typeof msg !== "object") return;

    // Another window requesting our full state
    if (msg.type === "sync-request") {
      const current = useSyncedStateStore.getState().settings;
      if (Object.keys(current).length > 0) {
        safeSend({ type: "sync-response", settings: current });
      }
      return;
    }

    // Response to our sync request — apply full state (first response only)
    if (msg.type === "sync-response" && !syncedFromRemote) {
      syncedFromRemote = true;
      const remote = msg.settings as Record<string, Record<string, unknown>>;
      if (!remote || typeof remote !== "object") return;
      isSyncing = true;
      set((state) => {
        const merged = { ...state.settings };
        for (const [pid, keys] of Object.entries(remote)) {
          merged[pid] = { ...merged[pid], ...keys };
        }
        return { settings: merged };
      });
      isSyncing = false;
      return;
    }

    // Regular per-key update
    const { namespace, key, value } = msg;
    if (typeof namespace !== "string" || typeof key !== "string") return;
    isSyncing = true;
    set((state) => ({
      settings: {
        ...state.settings,
        [namespace]: { ...state.settings[namespace], [key]: value },
      },
    }));
    isSyncing = false;
  };

  if (typeof window !== "undefined") {
    window.addEventListener("beforeunload", () => {
      channel?.close();
      channel = null;
    });
  }

  // Request existing state from other windows on init
  setTimeout(() => safeSend({ type: "sync-request" }), 0);

  return {
    settings: {},
    _set: (namespace, key, value) => {
      set((state) => ({
        settings: {
          ...state.settings,
          [namespace]: { ...state.settings[namespace], [key]: value },
        },
      }));
      if (!isSyncing) {
        safeSend({ namespace, key, value });
      }
    },
  };
});

// ── Hook ───────────────────────────────────────────────────────

/**
 * Drop-in replacement for `useState` that syncs across Electron windows.
 *
 * @param namespace - Logical group for the state (e.g. panel id, feature area)
 * @param key       - Unique key within the namespace
 * @param defaultValue - Initial value when no synced value exists
 *
 * ```ts
 * // Before:
 * const [encodeVideo, setEncodeVideo] = useState(false);
 *
 * // After:
 * const [encodeVideo, setEncodeVideo] = useSyncedState("render-queue", "encodeVideo", false);
 * ```
 */
export function useSyncedState<T>(
  namespace: string,
  key: string,
  defaultValue: T,
): [T, (value: T | ((prev: T) => T)) => void] {
  // Stabilise defaultValue reference so object/array defaults
  // don't cause the selector to return a new reference every render.
  const defaultRef = useRef(defaultValue);

  const value = useSyncedStateStore(
    (state) => (state.settings[namespace]?.[key] as T) ?? defaultRef.current,
  );

  const storeSet = useSyncedStateStore((state) => state._set);

  const setValue = useCallback(
    (newValue: T | ((prev: T) => T)) => {
      if (typeof newValue === "function") {
        const current =
          (useSyncedStateStore.getState().settings[namespace]?.[key] as T) ??
          defaultRef.current;
        storeSet(namespace, key, (newValue as (prev: T) => T)(current));
      } else {
        storeSet(namespace, key, newValue);
      }
    },
    [namespace, key, storeSet],
  );

  return [value, setValue];
}
