import { create } from "zustand";
import type { LogEntry } from "../../shared/rpc-types";
import { withBroadcastSync } from "./broadcast-sync";

const DEFAULT_MAX_LOGS = 500;
const MAX_LOGS_KEY = "guava-console-max-logs";

function loadMaxLogs(): number {
  try {
    const raw = localStorage.getItem(MAX_LOGS_KEY);
    if (raw) {
      const n = parseInt(raw, 10);
      if (Number.isFinite(n) && n > 0) return n;
    }
  } catch { /* fallback */ }
  return DEFAULT_MAX_LOGS;
}

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
  maxLogs: number;

  appendLog: (entry: LogEntry) => void;
  clearLogs: () => void;
  setMaxLogs: (max: number) => void;
}

export const useConsoleStore = create<ConsoleState>(
  withBroadcastSync(
    { name: "console", syncKeys: ["logs", "maxLogs"] },
    (set) => ({
      logs: [],
      maxLogs: loadMaxLogs(),

      appendLog: (entry) => {
        const normalized = normalizeEntry(entry);
        set((state) => {
          const limit = state.maxLogs;
          return {
            logs: state.logs.length >= limit
              ? [...state.logs.slice(-(limit - 1)), normalized]
              : [...state.logs, normalized],
          };
        });
      },

      clearLogs: () => {
        set({ logs: [] });
        window.guavaEngine.call("console.clear", {}).catch(() => {});
      },

      setMaxLogs: (max) => {
        const clamped = Math.max(50, Math.min(10000, max));
        localStorage.setItem(MAX_LOGS_KEY, String(clamped));
        set((state) => ({
          maxLogs: clamped,
          logs: state.logs.length > clamped ? state.logs.slice(-clamped) : state.logs,
        }));
      },
    }),
  ),
);
