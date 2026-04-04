import { create } from "zustand";

export interface ConnectionState {
  connected: boolean;
  error: string | null;

  setConnected: (connected: boolean) => void;
  setError: (error: string | null) => void;
}

export const useConnectionStore = create<ConnectionState>((set) => ({
  connected: false,
  error: null,

  setConnected: (connected) => set({ connected, error: connected ? null : undefined }),
  setError: (error) => set({ error }),
}));
