/**
 * Cross-window panel settings store.
 *
 * Every value set here is automatically synced to other Electron windows
 * (popouts) via BroadcastChannel.  Use `usePanelSetting()` in panel
 * components as a drop-in replacement for `useState`.
 *
 * Guidelines:
 *   • Config / preference state       → usePanelSetting  (syncs across windows)
 *   • Ephemeral UI state (hover, loading, context menus) → useState  (local only)
 */

import { useCallback, useRef } from "react";
import { create } from "zustand";

// ── Store ──────────────────────────────────────────────────────

const CHANNEL_NAME = "guava-panel-settings";

interface PanelSettingsState {
  /** panelId → key → value */
  settings: Record<string, Record<string, unknown>>;
  /** @internal — use usePanelSetting() instead */
  _set: (panelId: string, key: string, value: unknown) => void;
}

let channel: BroadcastChannel | null = null;
let isSyncing = false;

function getChannel(): BroadcastChannel {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }
  return channel;
}

export const usePanelSettingsStore = create<PanelSettingsState>((set) => {
  let syncedFromRemote = false;

  // Listen for updates from other windows
  getChannel().onmessage = (event: MessageEvent) => {
    const msg = event.data;
    if (!msg || typeof msg !== "object") return;

    // Another window requesting our full state
    if (msg.type === "sync-request") {
      const current = usePanelSettingsStore.getState().settings;
      if (Object.keys(current).length > 0) {
        getChannel().postMessage({ type: "sync-response", settings: current });
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
    const { panelId, key, value } = msg;
    if (typeof panelId !== "string" || typeof key !== "string") return;
    isSyncing = true;
    set((state) => ({
      settings: {
        ...state.settings,
        [panelId]: { ...state.settings[panelId], [key]: value },
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
  setTimeout(() => getChannel().postMessage({ type: "sync-request" }), 0);

  return {
    settings: {},
    _set: (panelId, key, value) => {
      set((state) => ({
        settings: {
          ...state.settings,
          [panelId]: { ...state.settings[panelId], [key]: value },
        },
      }));
      if (!isSyncing) {
        getChannel().postMessage({ panelId, key, value });
      }
    },
  };
});

// ── Hook ───────────────────────────────────────────────────────

/**
 * Drop-in replacement for `useState` that syncs across Electron windows.
 *
 * ```ts
 * // Before:
 * const [encodeVideo, setEncodeVideo] = useState(false);
 *
 * // After:
 * const [encodeVideo, setEncodeVideo] = usePanelSetting("render-queue", "encodeVideo", false);
 * ```
 */
export function usePanelSetting<T>(
  panelId: string,
  key: string,
  defaultValue: T,
): [T, (value: T | ((prev: T) => T)) => void] {
  // Stabilise defaultValue reference so object/array defaults
  // don't cause the selector to return a new reference every render.
  const defaultRef = useRef(defaultValue);

  const value = usePanelSettingsStore(
    (state) => (state.settings[panelId]?.[key] as T) ?? defaultRef.current,
  );

  const storeSet = usePanelSettingsStore((state) => state._set);

  const setValue = useCallback(
    (newValue: T | ((prev: T) => T)) => {
      if (typeof newValue === "function") {
        const current =
          (usePanelSettingsStore.getState().settings[panelId]?.[key] as T) ??
          defaultRef.current;
        storeSet(panelId, key, (newValue as (prev: T) => T)(current));
      } else {
        storeSet(panelId, key, newValue);
      }
    },
    [panelId, key, storeSet],
  );

  return [value, setValue];
}
