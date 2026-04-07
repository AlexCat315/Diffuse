import { create } from "zustand";

export interface EditorState {
  settingsOpen: boolean;
  keybindingsOpen: boolean;

  /** Path of a script file that should be opened in ScriptViewer. Consumed and cleared by ScriptViewer. */
  pendingScriptPath: string | null;

  setSettingsOpen: (open: boolean) => void;
  toggleSettings: () => void;
  setKeybindingsOpen: (open: boolean) => void;
  toggleKeybindings: () => void;
  openScript: (path: string) => void;
  clearPendingScript: () => void;
}

export const useEditorStore = create<EditorState>((set) => ({
  settingsOpen: false,
  keybindingsOpen: false,
  pendingScriptPath: null,

  setSettingsOpen: (open) => set({ settingsOpen: open }),
  toggleSettings: () => set((state) => ({ settingsOpen: !state.settingsOpen })),
  setKeybindingsOpen: (open) => set({ keybindingsOpen: open }),
  toggleKeybindings: () => set((state) => ({ keybindingsOpen: !state.keybindingsOpen })),
  openScript: (path) => set({ pendingScriptPath: path }),
  clearPendingScript: () => set({ pendingScriptPath: null }),
}));
