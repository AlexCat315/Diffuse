import { create } from "zustand";
import { withBroadcastSync } from "./broadcast-sync";

export type ShadingMode = "solid" | "material" | "rendered" | "wireframe";
export type FpsDisplay = "viewport" | "none";

const PREFS_KEY = "guava-editor-prefs";

function loadFpsDisplay(): FpsDisplay {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (raw) {
      const p = JSON.parse(raw);
      if (p.fpsDisplay === "none") return "none";
    }
  } catch { /* fallback */ }
  return "viewport";
}

export interface ViewportSettingsState {
  shadingMode: ShadingMode;
  fpsLimit: number;
  fpsDisplay: FpsDisplay;

  setShadingMode: (mode: ShadingMode) => void;
  setFpsLimit: (fps: number) => void;
  setFpsDisplay: (display: FpsDisplay) => void;
  fetchFromEngine: () => Promise<void>;
}

export const useViewportSettingsStore = create<ViewportSettingsState>(
  withBroadcastSync(
    { name: "viewport-settings", syncKeys: ["shadingMode", "fpsLimit", "fpsDisplay"] },
    (set) => ({
      shadingMode: "material",
      fpsLimit: 60,
      fpsDisplay: loadFpsDisplay(),

      setShadingMode: (mode) => {
        set({ shadingMode: mode });
        window.guavaEngine
          .call("viewport.setRenderSettings", { shadingMode: mode } as never)
          .catch(() => {});
      },
      setFpsLimit: (fps) => {
        set({ fpsLimit: fps });
        window.guavaEngine
          .call("viewport.setFrameRate", { fps } as never)
          .catch(() => {});
      },
      setFpsDisplay: (display) => {
        set({ fpsDisplay: display });
        try {
          const raw = localStorage.getItem(PREFS_KEY);
          const prefs = raw ? JSON.parse(raw) : {};
          prefs.fpsDisplay = display;
          localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
        } catch { /* ignore */ }
      },
      fetchFromEngine: async () => {
        try {
          const rs = await window.guavaEngine.call("viewport.getRenderSettings", {});
          if (rs.shadingMode) set({ shadingMode: rs.shadingMode as ShadingMode });
        } catch { /* ignore */ }
        try {
          const fr = await window.guavaEngine.call("viewport.getFrameRate", {});
          if (fr.fps != null) set({ fpsLimit: Number(fr.fps) });
        } catch { /* ignore */ }
      },
    }),
  ),
);
