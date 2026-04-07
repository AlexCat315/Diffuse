import { create } from "zustand";
import type { LogEntry } from "../../shared/rpc-types";
import { withBroadcastSync } from "./broadcast-sync";

/** LogEntry with a stable unique id for React keys. */
export interface ConsoleLogEntry extends LogEntry {
  _id: number;
}

let _nextId = 1;

/**
 * When true, log trimming is paused (user is reading, not at bottom).
 * Logs still accumulate up to a hard cap (4× maxLogs) as a safety net.
 * When unpaused, normal trimming at maxLogs resumes on the next append.
 */
let _trimPaused = false;

/** Called by the Console UI when the user scrolls away from / back to bottom. */
export function setConsoleTrimPaused(paused: boolean) {
  _trimPaused = paused;
}

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

function normalizeEntry(entry: LogEntry): ConsoleLogEntry {
  return {
    ...entry,
    level: LEVEL_MAP[entry.level] ?? entry.level.toLowerCase(),
    timestamp: entry.timestamp ?? Date.now(),
    _id: _nextId++,
  };
}

export interface ConsoleState {
  logs: ConsoleLogEntry[];
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
          const softLimit = state.maxLogs;
          // When paused (user reading), allow buffer to grow up to 4× before trimming
          const hardLimit = softLimit * 4;
          const limit = _trimPaused ? hardLimit : softLimit;
          return {
            logs: state.logs.length >= limit
              ? [...state.logs.slice(-(softLimit - 1)), normalized]
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
