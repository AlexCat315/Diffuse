import { create } from "zustand";

export type ToastLevel = "info" | "success" | "warning" | "error";

export interface ToastItem {
  id: number;
  level: ToastLevel;
  message: string;
  /** auto-dismiss delay in ms; 0 = sticky */
  duration: number;
}

interface ToastState {
  items: ToastItem[];
  add: (level: ToastLevel, message: string, duration?: number) => void;
  dismiss: (id: number) => void;
}

let nextId = 1;

const DEFAULT_DURATIONS: Record<ToastLevel, number> = {
  info: 3000,
  success: 2500,
  warning: 5000,
  error: 8000,
};

export const useToastStore = create<ToastState>((set) => ({
  items: [],
  add: (level, message, duration) =>
    set((s) => ({
      items: [
        ...s.items,
        { id: nextId++, level, message, duration: duration ?? DEFAULT_DURATIONS[level] },
      ],
    })),
  dismiss: (id) => set((s) => ({ items: s.items.filter((t) => t.id !== id) })),
}));

/** Convenience helpers importable from anywhere */
export const toast = {
  info: (msg: string, ms?: number) => useToastStore.getState().add("info", msg, ms),
  success: (msg: string, ms?: number) => useToastStore.getState().add("success", msg, ms),
  warn: (msg: string, ms?: number) => useToastStore.getState().add("warning", msg, ms),
  error: (msg: string, ms?: number) => useToastStore.getState().add("error", msg, ms),
};
