/**
 * Shared shortcut configuration — single source of truth for all keybindings.
 * Used by KeybindingsPanel (UI), Viewport (gizmo keys), and App (editor keys).
 */

export interface ShortcutBinding {
  key: string;   // lowercase letter or named key ("delete", "space", etc.)
  ctrl: boolean;
  shift: boolean;
  alt: boolean;
}

// ── Storage keys ──────────────────────────────────────────────────

export const GIZMO_SHORTCUTS_STORAGE_KEY = "guava-editor-gizmo-shortcuts";
export const MESH_SHORTCUTS_STORAGE_KEY = "guava-editor-shortcuts";

// ── Gizmo shortcut definitions ────────────────────────────────────

export interface GizmoShortcutDef {
  id: string;
  default: ShortcutBinding;
}

export const GIZMO_SHORTCUT_DEFS: GizmoShortcutDef[] = [
  { id: "select",    default: { key: "q", ctrl: false, shift: false, alt: false } },
  { id: "translate", default: { key: "w", ctrl: false, shift: false, alt: false } },
  { id: "rotate",    default: { key: "e", ctrl: false, shift: false, alt: false } },
  { id: "scale",     default: { key: "r", ctrl: false, shift: false, alt: false } },
];

export function loadGizmoShortcuts(): Record<string, ShortcutBinding> {
  try {
    const raw = localStorage.getItem(GIZMO_SHORTCUTS_STORAGE_KEY);
    if (raw) return { ...buildGizmoDefaults(), ...JSON.parse(raw) };
  } catch { /* ignore */ }
  return buildGizmoDefaults();
}

export function saveGizmoShortcuts(shortcuts: Record<string, ShortcutBinding>) {
  localStorage.setItem(GIZMO_SHORTCUTS_STORAGE_KEY, JSON.stringify(shortcuts));
}

function buildGizmoDefaults(): Record<string, ShortcutBinding> {
  const d: Record<string, ShortcutBinding> = {};
  for (const def of GIZMO_SHORTCUT_DEFS) d[def.id] = { ...def.default };
  return d;
}

// ── Mesh shortcut definitions ─────────────────────────────────────

export interface MeshShortcutDef {
  id: string;
  default: ShortcutBinding;
  /** Canonical key forwarded to engine if remapped */
  engineKey: string;
}

export const MESH_SHORTCUT_DEFS: MeshShortcutDef[] = [
  { id: "extrude",          default: { key: "e", ctrl: false, shift: false, alt: false }, engineKey: "e" },
  { id: "inset",            default: { key: "i", ctrl: false, shift: false, alt: false }, engineKey: "i" },
  { id: "bevel",            default: { key: "b", ctrl: false, shift: false, alt: false }, engineKey: "b" },
  { id: "loopCut",          default: { key: "r", ctrl: true,  shift: false, alt: false }, engineKey: "r" },
  { id: "merge",            default: { key: "m", ctrl: false, shift: false, alt: false }, engineKey: "m" },
  { id: "duplicateFaces",   default: { key: "d", ctrl: false, shift: true,  alt: false }, engineKey: "d" },
  { id: "separateFaces",    default: { key: "p", ctrl: false, shift: false, alt: false }, engineKey: "p" },
  { id: "recalcNormals",    default: { key: "n", ctrl: false, shift: true,  alt: false }, engineKey: "n" },
  { id: "pivotToSelection", default: { key: ".", ctrl: false, shift: false, alt: false }, engineKey: "." },
  { id: "subdivide",        default: { key: "s", ctrl: false, shift: true,  alt: false }, engineKey: "s" },
  { id: "dissolveVerts",    default: { key: "x", ctrl: false, shift: false, alt: false }, engineKey: "x" },
  { id: "selectAll",        default: { key: "a", ctrl: false, shift: false, alt: false }, engineKey: "a" },
  { id: "fillFace",         default: { key: "f", ctrl: false, shift: false, alt: false }, engineKey: "f" },
];

export function loadMeshShortcuts(): Record<string, ShortcutBinding> {
  try {
    const raw = localStorage.getItem(MESH_SHORTCUTS_STORAGE_KEY);
    if (raw) return { ...buildMeshDefaults(), ...JSON.parse(raw) };
  } catch { /* ignore */ }
  return buildMeshDefaults();
}

export function saveMeshShortcuts(shortcuts: Record<string, ShortcutBinding>) {
  localStorage.setItem(MESH_SHORTCUTS_STORAGE_KEY, JSON.stringify(shortcuts));
}

function buildMeshDefaults(): Record<string, ShortcutBinding> {
  const d: Record<string, ShortcutBinding> = {};
  for (const def of MESH_SHORTCUT_DEFS) d[def.id] = { ...def.default };
  return d;
}

// ── Editor-level shortcuts (fixed, not user-configurable) ─────────

export interface EditorFixedShortcut {
  id: string;
  display: string; // e.g. "Ctrl+S"
}

export const EDITOR_FIXED_SHORTCUTS: EditorFixedShortcut[] = [
  { id: "save",            display: "Ctrl+S" },
  { id: "undo",            display: "Ctrl+Z" },
  { id: "redo",            display: "Ctrl+Shift+Z" },
  { id: "togglePanel",     display: "Ctrl+J" },
  { id: "play",            display: "Space" },
  { id: "pause",           display: "Ctrl+Space" },
  { id: "stop",            display: "Shift+Space" },
  { id: "openSettings",    display: "Ctrl+," },
  { id: "openKeybindings", display: "Ctrl+K" },
];

// ── Helpers ──────────────────────────────────────────────────────

export function formatBinding(b: ShortcutBinding): string {
  const parts: string[] = [];
  if (b.ctrl) parts.push("Ctrl");
  if (b.shift) parts.push("Shift");
  if (b.alt) parts.push("Alt");
  parts.push(b.key.toUpperCase());
  return parts.join("+");
}

/** Check if a KeyboardEvent matches a ShortcutBinding */
export function matchesBinding(e: KeyboardEvent | React.KeyboardEvent, b: ShortcutBinding): boolean {
  const key = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase();
  const bKey = b.key.toLowerCase();
  return key === bKey &&
    !!(e.ctrlKey || (e as KeyboardEvent).metaKey) === b.ctrl &&
    !!e.shiftKey === b.shift &&
    !!e.altKey === b.alt;
}
