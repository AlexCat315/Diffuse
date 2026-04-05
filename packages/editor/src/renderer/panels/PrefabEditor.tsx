import React, { useEffect, useCallback, useMemo, useRef } from "react";
import { useLocalState } from "../store/local-state";
import { rpc } from "../rpc";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";
import { useConnectionStore, useSceneStore } from "../store";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";

// ── Types ───────────────────────────────────────────────────────

interface PrefabInfo {
  id: string;
  name: string;
  version: number;
  entityCount: number;
  sourcePath?: string;
}

interface PrefabEntityNode {
  prefabEntityId: number;
  name: string;
  parentId?: number;
  visible: boolean;
  isFolder: boolean;
  hasTransform: boolean;
  hasMesh: boolean;
  hasMaterial: boolean;
  hasLight: boolean;
  hasCamera: boolean;
  hasScript: boolean;
  hasVfx: boolean;
}

interface EntityDetail {
  prefabEntityId: number;
  name: string;
  visible: boolean;
  isFolder: boolean;
  posX: number; posY: number; posZ: number;
  rotX: number; rotY: number; rotZ: number; rotW: number;
  scaleX: number; scaleY: number; scaleZ: number;
  components: string[];
}

interface TreeNode extends PrefabEntityNode {
  children: TreeNode[];
  depth: number;
}

// ── Helpers ─────────────────────────────────────────────────────

function buildTree(entities: PrefabEntityNode[]): TreeNode[] {
  const map = new Map<number, TreeNode>();
  const roots: TreeNode[] = [];

  for (const e of entities) {
    map.set(e.prefabEntityId, { ...e, children: [], depth: 0 });
  }

  for (const e of entities) {
    const node = map.get(e.prefabEntityId)!;
    if (e.parentId != null) {
      const parent = map.get(e.parentId);
      if (parent) {
        node.depth = parent.depth + 1;
        parent.children.push(node);
      } else {
        roots.push(node);
      }
    } else {
      roots.push(node);
    }
  }

  return roots;
}

function flattenTree(nodes: TreeNode[]): TreeNode[] {
  const result: TreeNode[] = [];
  const visit = (list: TreeNode[]) => {
    for (const n of list) {
      result.push(n);
      visit(n.children);
    }
  };
  visit(nodes);
  return result;
}

const COMPONENT_ICONS: Record<string, string> = {
  Camera: "📷", Mesh: "🔷", Material: "🎨", Light: "💡",
  Rigidbody: "⚙️", BoxCollider: "📦", SphereCollider: "⚽",
  MeshCollider: "🔶", Vfx: "✨", Script: "📜", Animator: "🏃",
};

// ── Main Component ──────────────────────────────────────────────

export function PrefabEditor() {
  const connected = useConnectionStore((s) => s.connected);
  const selectedEntityId = useSceneStore((s) => s.selectedEntity);
  const { t } = useI18n();

  const [prefabs, setPrefabs] = useLocalState<PrefabInfo[]>([]);
  const [search, setSearch] = useLocalState("");
  const [selectedPrefab, setSelectedPrefab] = useLocalState<string | null>(null);
  const [entities, setEntities] = useLocalState<PrefabEntityNode[]>([]);
  const [selectedEntity, setSelectedEntity] = useLocalState<number | null>(null);
  const [detail, setDetail] = useLocalState<EntityDetail | null>(null);
  const [collapsed, setCollapsed] = useSyncedState<Set<number>>("prefab-editor", "collapsed", new Set());
  const [busy, setBusy] = useLocalState(false);
  const commitTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  // ── Fetch all prefabs ───────────────────────────────────────

  const fetchPrefabs = useCallback(async () => {
    if (!connected) return;
    try {
      const r = await rpc("prefab.list", {});
      setPrefabs(r.prefabs as unknown as PrefabInfo[]);
    } catch { /* ignore */ }
  }, [connected]);

  useEffect(() => { fetchPrefabs(); }, [fetchPrefabs]);

  // ── Fetch entities for selected prefab ──────────────────────

  const fetchEntities = useCallback(async (pid: string) => {
    if (!connected) return;
    try {
      const r = await rpc("prefab.getEntities", { prefabId: pid });
      if (r.found) {
        setEntities(r.entities as unknown as PrefabEntityNode[]);
      } else {
        setEntities([]);
      }
    } catch { setEntities([]); }
  }, [connected]);

  useEffect(() => {
    if (selectedPrefab) {
      fetchEntities(selectedPrefab);
      setSelectedEntity(null);
      setDetail(null);
    }
  }, [selectedPrefab, fetchEntities]);

  // ── Fetch entity detail ─────────────────────────────────────

  const fetchDetail = useCallback(async (pid: string, eid: number) => {
    if (!connected) return;
    try {
      const r = await rpc("prefab.getEntityDetail", { prefabId: pid, prefabEntityId: eid });
      if (r.found && r.entity) {
        setDetail(r.entity as unknown as EntityDetail);
      }
    } catch { /* ignore */ }
  }, [connected]);

  useEffect(() => {
    if (selectedPrefab && selectedEntity != null) {
      fetchDetail(selectedPrefab, selectedEntity);
    } else {
      setDetail(null);
    }
  }, [selectedPrefab, selectedEntity, fetchDetail]);

  // ── Commit transform (debounced) ────────────────────────────

  const commitTransform = useCallback((partial: Record<string, number>) => {
    setDetail((prev) => (prev ? { ...prev, ...partial } : prev));
    if (!selectedPrefab || selectedEntity == null) return;
    clearTimeout(commitTimer.current);
    const pid = selectedPrefab;
    const eid = selectedEntity;
    commitTimer.current = setTimeout(() => {
      rpc("prefab.setEntityTransform", { prefabId: pid, prefabEntityId: eid, ...partial } as never).catch(() => {});
    }, 100);
  }, [selectedPrefab, selectedEntity]);

  // ── Set field ───────────────────────────────────────────────

  const setField = useCallback(async (field: string, value: string) => {
    if (!selectedPrefab || selectedEntity == null) return;
    try {
      await rpc("prefab.setEntityField", {
        prefabId: selectedPrefab,
        prefabEntityId: selectedEntity,
        field,
        value,
      });
      fetchDetail(selectedPrefab, selectedEntity);
      if (field === "name") fetchEntities(selectedPrefab);
    } catch { /* ignore */ }
  }, [selectedPrefab, selectedEntity, fetchDetail, fetchEntities]);

  // ── Actions ─────────────────────────────────────────────────

  const doCreate = useCallback(async () => {
    if (!connected || selectedEntityId == null) return;
    const name = prompt(t.prefab.enterName);
    if (!name) return;
    setBusy(true);
    try {
      const r = await rpc("prefab.create", { entityId: selectedEntityId, name });
      if (r.success) {
        await fetchPrefabs();
        if (r.prefabId) setSelectedPrefab(r.prefabId);
      }
    } catch { /* ignore */ }
    setBusy(false);
  }, [connected, selectedEntityId, fetchPrefabs, t]);

  const doInstantiate = useCallback(async () => {
    if (!selectedPrefab) return;
    setBusy(true);
    try {
      await rpc("prefab.instantiate", { prefabId: selectedPrefab });
    } catch { /* ignore */ }
    setBusy(false);
  }, [selectedPrefab]);

  const doSave = useCallback(async () => {
    if (!selectedPrefab) return;
    setBusy(true);
    try {
      await rpc("prefab.save", { prefabId: selectedPrefab });
    } catch { /* ignore */ }
    setBusy(false);
  }, [selectedPrefab]);

  const doDelete = useCallback(async () => {
    if (!selectedPrefab) return;
    if (!confirm(t.prefab.confirmDelete)) return;
    setBusy(true);
    try {
      await rpc("prefab.delete", { prefabId: selectedPrefab });
      setSelectedPrefab(null);
      setEntities([]);
      setDetail(null);
      await fetchPrefabs();
    } catch { /* ignore */ }
    setBusy(false);
  }, [selectedPrefab, fetchPrefabs, t]);

  // ── Build tree + filter ─────────────────────────────────────

  const tree = useMemo(() => buildTree(entities), [entities]);
  const flat = useMemo(() => flattenTree(tree), [tree]);

  const filteredPrefabs = useMemo(() => {
    if (!search) return prefabs;
    const q = search.toLowerCase();
    return prefabs.filter((p) => p.name.toLowerCase().includes(q) || p.id.toLowerCase().includes(q));
  }, [prefabs, search]);

  const toggleCollapse = (id: number) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  // ── Visible flat nodes (respecting collapse) ────────────────

  const visibleNodes = useMemo(() => {
    const collapsedSet = collapsed;
    const result: TreeNode[] = [];
    const skip = new Set<number>();
    for (const node of flat) {
      if (skip.has(node.parentId ?? -1)) {
        skip.add(node.prefabEntityId);
        continue;
      }
      result.push(node);
      if (collapsedSet.has(node.prefabEntityId)) {
        skip.add(node.prefabEntityId);
      }
    }
    return result;
  }, [flat, collapsed]);

  // ── Render ──────────────────────────────────────────────────

  if (!connected) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>{t.prefab.title}</div>
        <div style={styles.empty}>{t.prefab.notConnected}</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>{t.prefab.title}</div>

      {/* ── Toolbar ──────────────────────────────────── */}
      <div style={styles.toolbar}>
        <button style={styles.btn} onClick={doCreate} disabled={busy || selectedEntityId == null} title={t.prefab.createFromEntity}>
          {t.prefab.create}
        </button>
        <button style={styles.btn} onClick={doInstantiate} disabled={busy || !selectedPrefab}>
          {t.prefab.instantiate}
        </button>
        <button style={styles.btn} onClick={doSave} disabled={busy || !selectedPrefab}>
          {t.prefab.save}
        </button>
        <button style={{ ...styles.btn, color: "#f38ba8" }} onClick={doDelete} disabled={busy || !selectedPrefab}>
          {t.prefab.delete}
        </button>
        <button style={styles.btn} onClick={fetchPrefabs}>{t.prefab.refresh}</button>
      </div>

      {/* ── Split pane ───────────────────────────────── */}
      <div style={styles.splitPane}>
        {/* ── Left: Prefab list ──────────────────────── */}
        <div style={styles.leftPane}>
          <input
            style={styles.searchInput}
            placeholder={t.prefab.search}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <div style={styles.listScroll}>
            {filteredPrefabs.length === 0 ? (
              <div style={{ padding: 12, opacity: 0.4, fontSize: 12 }}>{t.prefab.noPrefabs}</div>
            ) : (
              filteredPrefabs.map((p) => (
                <div
                  key={p.id}
                  onClick={() => setSelectedPrefab(p.id)}
                  style={{
                    ...styles.listItem,
                    background: selectedPrefab === p.id ? "#45475a" : "transparent",
                  }}
                >
                  <span style={{ color: "#cdd6f4", fontSize: 12 }}>{p.name}</span>
                  <span style={styles.badge}>v{p.version} • {p.entityCount}e</span>
                </div>
              ))
            )}
          </div>
        </div>

        {/* ── Right: Entity tree + Inspector ─────────── */}
        <div style={styles.rightPane}>
          {!selectedPrefab ? (
            <div style={styles.empty}>{t.prefab.selectPrefab}</div>
          ) : (
            <>
              {/* Prefab metadata */}
              {(() => {
                const p = prefabs.find((x) => x.id === selectedPrefab);
                return p ? (
                  <div style={styles.metaBar}>
                    <span style={{ fontWeight: 600, color: "#cdd6f4" }}>{p.name}</span>
                    <span style={{ color: "#6c7086", fontSize: 11 }}>v{p.version} • {p.entityCount} entities</span>
                    {p.sourcePath && <span style={{ color: "#6c7086", fontSize: 10 }}>{p.sourcePath}</span>}
                  </div>
                ) : null;
              })()}

              {/* Entity tree */}
              <div style={styles.treeSection}>
                <div style={{ fontSize: 11, fontWeight: 600, color: "#a6adc8", padding: "4px 0" }}>
                  {t.prefab.entityTree}
                </div>
                <div style={styles.treeScroll}>
                  {visibleNodes.map((node) => {
                    const hasChildren = node.children.length > 0;
                    const isCollapsed = collapsed.has(node.prefabEntityId);
                    return (
                      <div
                        key={node.prefabEntityId}
                        onClick={() => setSelectedEntity(node.prefabEntityId)}
                        style={{
                          ...styles.treeItem,
                          paddingLeft: 8 + node.depth * 16,
                          background: selectedEntity === node.prefabEntityId ? "#45475a" : "transparent",
                        }}
                      >
                        {hasChildren ? (
                          <span
                            style={styles.arrow}
                            onClick={(e) => { e.stopPropagation(); toggleCollapse(node.prefabEntityId); }}
                          >
                            {isCollapsed ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}
                          </span>
                        ) : (
                          <span style={{ width: 12 }} />
                        )}
                        <span style={{ fontSize: 12, color: node.visible ? "#cdd6f4" : "#6c7086" }}>
                          {node.isFolder ? "📁 " : ""}{node.name}
                        </span>
                        <span style={styles.componentFlags}>
                          {node.hasMesh && COMPONENT_ICONS.Mesh}
                          {node.hasMaterial && COMPONENT_ICONS.Material}
                          {node.hasLight && COMPONENT_ICONS.Light}
                          {node.hasCamera && COMPONENT_ICONS.Camera}
                          {node.hasScript && COMPONENT_ICONS.Script}
                          {node.hasVfx && COMPONENT_ICONS.Vfx}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* Entity Inspector */}
              {detail && (
                <div style={styles.inspectorSection}>
                  <div style={{ fontSize: 11, fontWeight: 600, color: "#a6adc8", padding: "4px 0" }}>
                    {t.prefab.inspector}
                  </div>

                  {/* Name */}
                  <InlineEdit
                    label={t.prefab.name}
                    value={detail.name}
                    onCommit={(v) => setField("name", v)}
                  />

                  {/* Visible */}
                  <div style={styles.field}>
                    <label style={styles.label}>{t.prefab.visible}</label>
                    <input
                      type="checkbox" checked={detail.visible}
                      onChange={(e) => setField("visible", String(e.target.checked))}
                      style={{ accentColor: "#89b4fa" }}
                    />
                  </div>

                  {/* Transform */}
                  <div style={{ fontSize: 11, fontWeight: 600, color: "#a6adc8", padding: "6px 0 2px" }}>
                    {t.prefab.transform}
                  </div>
                  <Vec3Row label={t.prefab.position} x={detail.posX} y={detail.posY} z={detail.posZ}
                    onChange={(axis, v) => commitTransform({ [`pos${axis}`]: v })} />
                  <Vec4Row label={t.prefab.rotation} x={detail.rotX} y={detail.rotY} z={detail.rotZ} w={detail.rotW}
                    onChange={(axis, v) => commitTransform({ [`rot${axis}`]: v })} />
                  <Vec3Row label={t.prefab.scale} x={detail.scaleX} y={detail.scaleY} z={detail.scaleZ}
                    onChange={(axis, v) => commitTransform({ [`scale${axis}`]: v })} />

                  {/* Components */}
                  <div style={{ fontSize: 11, fontWeight: 600, color: "#a6adc8", padding: "6px 0 2px" }}>
                    {t.prefab.components}
                  </div>
                  <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                    {detail.components.map((c) => (
                      <span key={c} style={styles.componentBadge}>
                        {COMPONENT_ICONS[c] ?? "🔧"} {c}
                      </span>
                    ))}
                    {detail.components.length === 0 && (
                      <span style={{ fontSize: 11, opacity: 0.4 }}>{t.prefab.noComponents}</span>
                    )}
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Sub-components ──────────────────────────────────────────────

function InlineEdit({ label, value, onCommit }: { label: string; value: string; onCommit: (v: string) => void }) {
  const [editing, setEditing] = useLocalState(false);
  const [draft, setDraft] = useLocalState(value);

  useEffect(() => { setDraft(value); }, [value]);

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      {editing ? (
        <input
          style={styles.textInput}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={() => { onCommit(draft); setEditing(false); }}
          onKeyDown={(e) => { if (e.key === "Enter") { onCommit(draft); setEditing(false); } if (e.key === "Escape") setEditing(false); }}
          autoFocus
        />
      ) : (
        <span style={{ color: "#cdd6f4", fontSize: 12, cursor: "pointer" }} onDoubleClick={() => setEditing(true)}>
          {value}
        </span>
      )}
    </div>
  );
}

function Vec3Row({ label, x, y, z, onChange }: {
  label: string; x: number; y: number; z: number;
  onChange: (axis: string, val: number) => void;
}) {
  return (
    <div style={styles.vecRow}>
      <label style={{ ...styles.label, minWidth: 60 }}>{label}</label>
      <NumInput label="X" value={x} color="#f38ba8" onChange={(v) => onChange("X", v)} />
      <NumInput label="Y" value={y} color="#a6e3a1" onChange={(v) => onChange("Y", v)} />
      <NumInput label="Z" value={z} color="#89b4fa" onChange={(v) => onChange("Z", v)} />
    </div>
  );
}

function Vec4Row({ label, x, y, z, w, onChange }: {
  label: string; x: number; y: number; z: number; w: number;
  onChange: (axis: string, val: number) => void;
}) {
  return (
    <div style={styles.vecRow}>
      <label style={{ ...styles.label, minWidth: 60 }}>{label}</label>
      <NumInput label="X" value={x} color="#f38ba8" onChange={(v) => onChange("X", v)} />
      <NumInput label="Y" value={y} color="#a6e3a1" onChange={(v) => onChange("Y", v)} />
      <NumInput label="Z" value={z} color="#89b4fa" onChange={(v) => onChange("Z", v)} />
      <NumInput label="W" value={w} color="#cba6f7" onChange={(v) => onChange("W", v)} />
    </div>
  );
}

function NumInput({ label, value, color, onChange }: {
  label: string; value: number; color: string; onChange: (v: number) => void;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 2, flex: 1 }}>
      <span style={{ fontSize: 10, color, fontWeight: 600 }}>{label}</span>
      <input
        type="number"
        step={0.1}
        value={Number(value.toFixed(4))}
        onChange={(e) => { const v = parseFloat(e.target.value); if (!isNaN(v)) onChange(v); }}
        style={styles.numInput}
      />
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" },
  header: {
    padding: "8px 12px", borderBottom: "1px solid #313244",
    fontSize: 12, fontWeight: 600, textTransform: "uppercase",
    letterSpacing: 0.5, color: "#a6adc8", flexShrink: 0,
  },
  toolbar: {
    display: "flex", gap: 4, padding: "6px 12px",
    borderBottom: "1px solid #313244", flexShrink: 0, flexWrap: "wrap",
  },
  btn: {
    background: "#313244", border: "1px solid #45475a", borderRadius: 3,
    color: "#cdd6f4", padding: "3px 8px", fontSize: 11, cursor: "pointer",
  },
  empty: { padding: 24, textAlign: "center", opacity: 0.4, fontSize: 13, flexGrow: 1 },
  splitPane: { display: "flex", flex: 1, overflow: "hidden" },
  leftPane: {
    width: "30%", minWidth: 160, maxWidth: 280, borderRight: "1px solid #313244",
    display: "flex", flexDirection: "column",
  },
  rightPane: { flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" },
  searchInput: {
    width: "100%", background: "#1e1e2e", border: "none",
    borderBottom: "1px solid #313244", color: "#cdd6f4",
    padding: "6px 10px", fontSize: 12, outline: "none",
  },
  listScroll: { flex: 1, overflowY: "auto" },
  listItem: {
    display: "flex", justifyContent: "space-between", alignItems: "center",
    padding: "5px 10px", cursor: "pointer",
  },
  badge: { fontSize: 10, color: "#6c7086" },
  metaBar: {
    padding: "6px 12px", borderBottom: "1px solid #313244",
    display: "flex", gap: 8, alignItems: "center", flexShrink: 0,
  },
  treeSection: { padding: "4px 12px", borderBottom: "1px solid #313244", flexShrink: 0, maxHeight: "40%" },
  treeScroll: { overflowY: "auto", maxHeight: 260 },
  treeItem: {
    display: "flex", alignItems: "center", gap: 4, padding: "3px 8px",
    cursor: "pointer", borderRadius: 3,
  },
  arrow: { width: 12, display: "inline-flex", cursor: "pointer", color: "#6c7086" },
  componentFlags: { marginLeft: "auto", fontSize: 10 },
  inspectorSection: { flex: 1, padding: "6px 12px", overflowY: "auto" },
  field: { display: "flex", alignItems: "center", padding: "2px 0", fontSize: 12, gap: 6 },
  label: { color: "#a6adc8", minWidth: 70, fontSize: 11 },
  vecRow: { display: "flex", alignItems: "center", gap: 4, padding: "2px 0" },
  numInput: {
    background: "#313244", border: "1px solid #45475a", borderRadius: 3,
    color: "#cdd6f4", padding: "2px 4px", fontSize: 11, width: "100%",
    outline: "none",
  },
  textInput: {
    background: "#313244", border: "1px solid #89b4fa", borderRadius: 3,
    color: "#cdd6f4", padding: "2px 6px", fontSize: 12, flex: 1, outline: "none",
  },
  componentBadge: {
    fontSize: 10, padding: "2px 6px", borderRadius: 8,
    background: "#313244", color: "#a6adc8", border: "1px solid #45475a",
  },
};
