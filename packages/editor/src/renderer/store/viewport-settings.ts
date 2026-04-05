import { create } from "zustand";

export type ShadingMode = "solid" | "material" | "rendered" | "wireframe";

export interface ViewportSettingsState {
  shadingMode: ShadingMode;
  fpsLimit: number;

  setShadingMode: (mode: ShadingMode) => void;
  setFpsLimit: (fps: number) => void;
  fetchFromEngine: () => Promise<void>;
}

export const useViewportSettingsStore = create<ViewportSettingsState>((set) => ({
  shadingMode: "material",
  fpsLimit: 60,

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
}));
