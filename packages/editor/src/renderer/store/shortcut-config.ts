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
  label: string;
  labelZh: string;
  default: ShortcutBinding;
}

export const GIZMO_SHORTCUT_DEFS: GizmoShortcutDef[] = [
  { id: "select",    label: "Select",    labelZh: "选择",  default: { key: "q", ctrl: false, shift: false, alt: false } },
  { id: "translate", label: "Translate", labelZh: "移动",  default: { key: "w", ctrl: false, shift: false, alt: false } },
  { id: "rotate",    label: "Rotate",    labelZh: "旋转",  default: { key: "e", ctrl: false, shift: false, alt: false } },
  { id: "scale",     label: "Scale",     labelZh: "缩放",  default: { key: "r", ctrl: false, shift: false, alt: false } },
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
  label: string;
  labelZh: string;
  default: ShortcutBinding;
  /** Canonical key forwarded to engine if remapped */
  engineKey: string;
}

export const MESH_SHORTCUT_DEFS: MeshShortcutDef[] = [
  { id: "extrude",          label: "Extrude",             labelZh: "挤出",       default: { key: "e", ctrl: false, shift: false, alt: false }, engineKey: "e" },
  { id: "inset",            label: "Inset",               labelZh: "内嵌",       default: { key: "i", ctrl: false, shift: false, alt: false }, engineKey: "i" },
  { id: "bevel",            label: "Bevel",               labelZh: "倒角",       default: { key: "b", ctrl: false, shift: false, alt: false }, engineKey: "b" },
  { id: "loopCut",          label: "Loop Cut",            labelZh: "环切",       default: { key: "r", ctrl: true,  shift: false, alt: false }, engineKey: "r" },
  { id: "merge",            label: "Merge",               labelZh: "合并",       default: { key: "m", ctrl: false, shift: false, alt: false }, engineKey: "m" },
  { id: "duplicateFaces",   label: "Duplicate Faces",     labelZh: "复制面",     default: { key: "d", ctrl: false, shift: true,  alt: false }, engineKey: "d" },
  { id: "separateFaces",    label: "Separate Faces",      labelZh: "分离面",     default: { key: "p", ctrl: false, shift: false, alt: false }, engineKey: "p" },
  { id: "recalcNormals",    label: "Recalculate Normals", labelZh: "重算法线",   default: { key: "n", ctrl: false, shift: true,  alt: false }, engineKey: "n" },
  { id: "pivotToSelection", label: "Pivot To Selection",  labelZh: "轴心到选区", default: { key: ".", ctrl: false, shift: false, alt: false }, engineKey: "." },
  { id: "subdivide",        label: "Subdivide",           labelZh: "细分",       default: { key: "s", ctrl: false, shift: true,  alt: false }, engineKey: "s" },
  { id: "dissolveVerts",    label: "Dissolve Vertices",   labelZh: "溶解顶点",   default: { key: "x", ctrl: false, shift: false, alt: false }, engineKey: "x" },
  { id: "selectAll",        label: "Select All / None",   labelZh: "全选 / 取消", default: { key: "a", ctrl: false, shift: false, alt: false }, engineKey: "a" },
  { id: "fillFace",         label: "Fill Face",           labelZh: "填充面",     default: { key: "f", ctrl: false, shift: false, alt: false }, engineKey: "f" },
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
  label: string;
  labelZh: string;
  display: string; // e.g. "Ctrl+S"
}

export const EDITOR_FIXED_SHORTCUTS: EditorFixedShortcut[] = [
  { id: "save",          label: "Save Scene",           labelZh: "保存场景",     display: "Ctrl+S" },
  { id: "undo",          label: "Undo",                 labelZh: "撤销",         display: "Ctrl+Z" },
  { id: "redo",          label: "Redo",                 labelZh: "重做",         display: "Ctrl+Shift+Z" },
  { id: "togglePanel",   label: "Toggle Bottom Panel",  labelZh: "切换底部面板", display: "Ctrl+J" },
  { id: "play",          label: "Play",                 labelZh: "播放",         display: "Space" },
  { id: "pause",         label: "Pause",                labelZh: "暂停",         display: "Ctrl+Space" },
  { id: "stop",          label: "Stop",                 labelZh: "停止",         display: "Shift+Space" },
  { id: "openSettings",  label: "Open Settings",        labelZh: "打开设置",     display: "Ctrl+," },
  { id: "openKeybindings", label: "Open Keybindings",  labelZh: "打开快捷键",   display: "Ctrl+K" },
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
