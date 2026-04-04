import { create } from "zustand";
import type { LogEntry } from "../../shared/rpc-types";

const MAX_LOGS = 500;

export interface ConsoleState {
  logs: LogEntry[];

  appendLog: (entry: LogEntry) => void;
  clearLogs: () => void;
}

export const useConsoleStore = create<ConsoleState>((set) => ({
  logs: [],

  appendLog: (entry) =>
    set((state) => ({
      logs: state.logs.length >= MAX_LOGS
        ? [...state.logs.slice(-(MAX_LOGS - 1)), entry]
        : [...state.logs, entry],
    })),

  clearLogs: () => {
    set({ logs: [] });
    window.guavaEngine.call("console.clear", {}).catch(() => {});
  },
}));
