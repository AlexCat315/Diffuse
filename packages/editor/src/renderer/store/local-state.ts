/**
 * Alias for React `useState` — marks state as window-local (not synced).
 *
 * Use `useLocalState` for ephemeral UI state that does NOT need to sync
 * across Electron popout windows (hover, loading, drag, search input, etc.).
 *
 * For state that SHOULD sync across windows, use `useSyncedState` instead.
 */
import { useState } from "react";

export const useLocalState = useState;
