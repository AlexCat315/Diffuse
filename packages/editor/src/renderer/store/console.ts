import { create } from "zustand";
import type { LogEntry } from "../../shared/rpc-types";

const MAX_LOGS = 500;

/** Map engine level labels (ERR/WRN/INF/DBG) to canonical names. */
const LEVEL_MAP: Record<string, string> = {
  ERR: "error",
  WRN: "warn",
  INF: "info",
  DBG: "debug",
};

function normalizeEntry(entry: LogEntry): LogEntry {
  return {
    ...entry,
    level: LEVEL_MAP[entry.level] ?? entry.level.toLowerCase(),
    timestamp: entry.timestamp ?? Date.now(),
  };
}

export interface ConsoleState {
  logs: LogEntry[];

  appendLog: (entry: LogEntry) => void;
  clearLogs: () => void;
}

export const useConsoleStore = create<ConsoleState>((set) => ({
  logs: [],

  appendLog: (entry) => {
    const normalized = normalizeEntry(entry);
    set((state) => ({
      logs: state.logs.length >= MAX_LOGS
        ? [...state.logs.slice(-(MAX_LOGS - 1)), normalized]
        : [...state.logs, normalized],
    }));
  },

  clearLogs: () => {
    set({ logs: [] });
    window.guavaEngine.call("console.clear", {}).catch(() => {});
  },
}));
