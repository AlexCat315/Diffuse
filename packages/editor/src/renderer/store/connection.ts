import { create } from "zustand";
import { withBroadcastSync } from "./broadcast-sync";

export interface ConnectionState {
  connected: boolean;
  error: string | null;

  setConnected: (connected: boolean) => void;
  setError: (error: string | null) => void;
}

export const useConnectionStore = create<ConnectionState>(
  withBroadcastSync(
    { name: "connection", syncKeys: ["connected", "error"] },
    (set, get) => ({
      connected: false,
      error: null,

      setConnected: (connected) => set({ connected, error: connected ? null : get().error }),
      setError: (error) => set({ error }),
    }),
  ),
);
