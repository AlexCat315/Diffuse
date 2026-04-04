import { create } from "zustand";

export interface EditorState {
  settingsOpen: boolean;

  setSettingsOpen: (open: boolean) => void;
  toggleSettings: () => void;
}

export const useEditorStore = create<EditorState>((set) => ({
  settingsOpen: false,

  setSettingsOpen: (open) => set({ settingsOpen: open }),
  toggleSettings: () => set((state) => ({ settingsOpen: !state.settingsOpen })),
}));
