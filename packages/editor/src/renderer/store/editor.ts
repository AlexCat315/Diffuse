import { create } from "zustand";

export interface EditorState {
  settingsOpen: boolean;
  keybindingsOpen: boolean;

  setSettingsOpen: (open: boolean) => void;
  toggleSettings: () => void;
  setKeybindingsOpen: (open: boolean) => void;
  toggleKeybindings: () => void;
}

export const useEditorStore = create<EditorState>((set) => ({
  settingsOpen: false,
  keybindingsOpen: false,

  setSettingsOpen: (open) => set({ settingsOpen: open }),
  toggleSettings: () => set((state) => ({ settingsOpen: !state.settingsOpen })),
  setKeybindingsOpen: (open) => set({ keybindingsOpen: open }),
  toggleKeybindings: () => set((state) => ({ keybindingsOpen: !state.keybindingsOpen })),
}));
