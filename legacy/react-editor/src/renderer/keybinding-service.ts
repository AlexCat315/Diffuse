/**
 * Unified Keybinding System
 *
 * Resolves keyboard shortcuts by context priority:
 *   1. Text editing → suppresses all non-modifier shortcuts
 *   2. Active panel local bindings → override globals for the same key
 *   3. Mode-specific bindings (e.g. meshEdit) → override panel defaults
 *   4. Global bindings → fallback
 *
 * Panels register their keybinding contexts; the dispatcher decides
 * which handler runs based on what's currently active.
 */

import { isTextEditingTarget } from "./keyboard-utils";

// ── Types ────────────────────────────────────────────────────────

/** Identifies a key combo.  Modifier booleans default to false. */
export interface KeyCombo {
  key: string;           // lower-case key value (e.g. "e", "s", "delete")
  ctrl?: boolean;        // Ctrl or Cmd
  shift?: boolean;
  alt?: boolean;
}

export interface KeyBinding {
  id: string;            // unique id, e.g. "gizmo.rotate", "meshEdit.extrude"
  combo: KeyCombo;
  /** Handler returns true if the event was consumed (stops further dispatch). */
  handler: (e: KeyboardEvent) => boolean | void;
}

/** A keybinding context groups bindings that are active together. */
export interface KeybindingContext {
  id: string;            // e.g. "global", "viewport", "viewport.meshEdit", "scriptEditor"
  /** Active predicate – checked on every key event.  Return false to skip. */
  when?: () => boolean;
  bindings: KeyBinding[];
}

// ── Normalise a KeyboardEvent into a KeyCombo ────────────────────

function eventToCombo(e: KeyboardEvent): KeyCombo {
  return {
    key: e.key.toLowerCase(),
    ctrl: e.ctrlKey || e.metaKey,
    shift: e.shiftKey,
    alt: e.altKey,
  };
}

function comboMatches(a: KeyCombo, b: KeyCombo): boolean {
  return a.key === b.key
    && (!!a.ctrl) === (!!b.ctrl)
    && (!!a.shift) === (!!b.shift)
    && (!!a.alt) === (!!b.alt);
}

// ── Service ──────────────────────────────────────────────────────

class KeybindingService {
  /**
   * Contexts ordered from highest to lowest priority.
   * The first matching binding wins.
   */
  private contexts: KeybindingContext[] = [];

  /** Currently focused panel component id (set by FlexLayout integration). */
  private _activePanel: string | null = null;

  get activePanel(): string | null { return this._activePanel; }
  set activePanel(id: string | null) { this._activePanel = id; }

  // ── Registration ────────────────────────────────────────

  /**
   * Register a context.  Contexts added first have higher priority.
   * Returns an unregister function.
   */
  register(ctx: KeybindingContext): () => void {
    this.contexts.push(ctx);
    return () => {
      this.contexts = this.contexts.filter((c) => c !== ctx);
    };
  }

  /**
   * Register a context at a specific priority index (0 = highest).
   * Returns an unregister function.
   */
  registerAt(index: number, ctx: KeybindingContext): () => void {
    this.contexts.splice(index, 0, ctx);
    return () => {
      this.contexts = this.contexts.filter((c) => c !== ctx);
    };
  }

  // ── Dispatch ────────────────────────────────────────────

  /**
   * Main dispatch entry point.  Called from a single document-level
   * capture-phase listener.  Returns true if the event was consumed.
   */
  dispatch(e: KeyboardEvent): boolean {
    // Priority 1: Text editing context — suppress non-modifier bare keys
    if (isTextEditingTarget(e)) {
      // Allow Ctrl/Cmd combos (Ctrl+S, Ctrl+Z) to propagate to the
      // text editor's own handlers — don't intercept them here.
      return false;
    }

    const combo = eventToCombo(e);

    for (const ctx of this.contexts) {
      // Skip contexts whose when-guard is false
      if (ctx.when && !ctx.when()) continue;

      for (const binding of ctx.bindings) {
        if (comboMatches(combo, binding.combo)) {
          const consumed = binding.handler(e);
          if (consumed !== false) {
            e.preventDefault();
            return true;
          }
          // handler returned false — continue checking lower-priority contexts
        }
      }
    }

    return false;
  }

  // ── Lifecycle ───────────────────────────────────────────

  private _listener: ((e: KeyboardEvent) => void) | null = null;

  /** Install the singleton document-level capture listener. */
  install(): void {
    if (this._listener) return;
    this._listener = (e: KeyboardEvent) => this.dispatch(e);
    document.addEventListener("keydown", this._listener, true);
  }

  /** Remove the listener (for cleanup). */
  uninstall(): void {
    if (this._listener) {
      document.removeEventListener("keydown", this._listener, true);
      this._listener = null;
    }
  }
}

// ── Singleton ────────────────────────────────────────────────────

export const keybindingService = new KeybindingService();
