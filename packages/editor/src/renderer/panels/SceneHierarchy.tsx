import React, { useCallback, useRef, useEffect } from "react";
import { useLocalState } from "../store/local-state";
import type { EntityNode } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import { IconClose, IconTriangleRight, IconTriangleDown, IconLockClosed, IconLockOpen, IconShadingRendered, IconEyeSlash } from "../components/Icons";
import { useSceneStore } from "../store";
import { engine } from "../engine-client";

export function SceneHierarchy() {
  const roots = useSceneStore((s) => s.hierarchy);
  const selectedId = useSceneStore((s) => s.selectedEntity);
  const onSelect = useSceneStore((s) => s.selectEntity);
  const onRefresh = useSceneStore((s) => s.refreshHierarchy);
  const { t } = useI18n();
  const [search, setSearch] = useLocalState("");
  const [contextMenu, setContextMenu] = useLocalState<{ x: number; y: number; entityId: number | null } | null>(null);
  const [renamingId, setRenamingId] = useLocalState<number | null>(null);

  // Close context menu on click elsewhere
  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [contextMenu]);

  const handleContextMenu = useCallback((e: React.MouseEvent, entityId: number | null) => {
    e.preventDefault();
    setContextMenu({ x: e.clientX, y: e.clientY, entityId });
  }, []);

  const createEntity = useCallback(async (parentId?: number) => {
    try {
      const result = await engine.call("scene.createEntity", {
        name: t.hierarchy.defaultEntityName,
        ...(parentId != null && { parentId }),
      });
      onRefresh();
      onSelect(result.entityId);
    } catch (e) {
      console.error("Failed to create entity:", e);
    }
  }, [onRefresh, onSelect]);

  const deleteEntity = useCallback(async (entityId: number) => {
    try {
      await engine.call("scene.deleteEntity", { entityId });
      onRefresh();
    } catch (e) {
      console.error("Failed to delete entity:", e);
    }
  }, [onRefresh]);

  const duplicateEntity = useCallback(async (entityId: number) => {
    try {
      await engine.call("scene.duplicateEntity", { entityId });
      onRefresh();
    } catch (e) {
      console.error("Failed to duplicate entity:", e);
    }
  }, [onRefresh]);

  const handleRename = useCallback(async (entityId: number, name: string) => {
    setRenamingId(null);
    if (!name.trim()) return;
    try {
      await engine.call("entity.setName", { entityId, name });
      onRefresh();
    } catch (e) {
      console.error("Failed to rename entity:", e);
    }
  }, [onRefresh]);

  const toggleVisible = useCallback(async (entityId: number, visible: boolean) => {
    try {
      await engine.call("entity.setVisible", { entityId, visible });
      onRefresh();
    } catch (e) {
      console.error("Failed to toggle visibility:", e);
    }
  }, [onRefresh]);

  const toggleSelectable = useCallback(async (entityId: number, selectable: boolean) => {
    try {
      await engine.call("entity.setSelectable", { entityId, selectable });
      onRefresh();
    } catch (e) {
      console.error("Failed to toggle selectable:", e);
    }
  }, [onRefresh]);

  const filteredRoots = search ? filterTree(roots, search.toLowerCase()) : roots;

  return (
    <div
      style={styles.container}
      tabIndex={0}
      onContextMenu={(e) => handleContextMenu(e, null)}
      onKeyDown={(e) => {
        if ((e.key === "Delete" || e.key === "Backspace") && selectedId != null && renamingId == null) {
          e.preventDefault();
          deleteEntity(selectedId);
        }
      }}
    >
      <div style={styles.header}>
        <span style={styles.title}>{t.hierarchy.title}</span>
      </div>

      {/* Search bar */}
      <div style={styles.searchBar}>
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={t.hierarchy.searchPlaceholder}
          style={styles.searchInput}
        />
        {search && (
          <span style={styles.clearSearch} onClick={() => setSearch("")}><IconClose size={12} /></span>
        )}
      </div>

      <div style={styles.tree}>
        {filteredRoots.length === 0 ? (
          <div style={styles.empty}>{search ? t.hierarchy.noMatchingEntities : t.hierarchy.noEntities}</div>
        ) : (
          filteredRoots.map((node) => (
            <TreeNode
              key={node.id}
              node={node}
              depth={0}
              selectedId={selectedId}
              onSelect={onSelect}
              onContextMenu={handleContextMenu}
              renamingId={renamingId}
              onRename={handleRename}
              onStartRename={setRenamingId}
              onToggleVisible={toggleVisible}
              onToggleSelectable={toggleSelectable}
            />
          ))
        )}
      </div>

      {/* Context menu */}
      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          entityId={contextMenu.entityId}
          onCreateEntity={() => createEntity(contextMenu.entityId ?? undefined)}
          onDeleteEntity={contextMenu.entityId != null ? () => deleteEntity(contextMenu.entityId!) : undefined}
          onDuplicate={contextMenu.entityId != null ? () => duplicateEntity(contextMenu.entityId!) : undefined}
          onRename={contextMenu.entityId != null ? () => setRenamingId(contextMenu.entityId!) : undefined}
          onClose={() => setContextMenu(null)}
        />
      )}
    </div>
  );
}

// ── Filter tree by search ────────────────────────────────────────

function filterTree(nodes: EntityNode[], query: string): EntityNode[] {
  const result: EntityNode[] = [];
  for (const node of nodes) {
    const childMatches = filterTree(node.children, query);
    if (node.name.toLowerCase().includes(query) || childMatches.length > 0) {
      result.push({ ...node, children: childMatches });
    }
  }
  return result;
}

// ── Context Menu ──────────────────────────────────────────────────

function ContextMenu({
  x, y, entityId,
  onCreateEntity, onDeleteEntity, onDuplicate, onRename, onClose,
}: {
  x: number; y: number; entityId: number | null;
  onCreateEntity: () => void;
  onDeleteEntity?: () => void;
  onDuplicate?: () => void;
  onRename?: () => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const items: { label: string; action: () => void; danger?: boolean }[] = [
    { label: entityId != null ? t.hierarchy.createChild : t.hierarchy.createEntity, action: onCreateEntity },
  ];
  if (onRename) items.push({ label: t.common.rename, action: onRename });
  if (onDuplicate) items.push({ label: t.common.duplicate, action: onDuplicate });
  if (onDeleteEntity) items.push({ label: t.common.delete, action: onDeleteEntity, danger: true });

  return (
    <div
      style={{ ...menuStyles.overlay }}
      onClick={(e) => { e.stopPropagation(); onClose(); }}
    >
      <div style={{ ...menuStyles.menu, left: x, top: y }} onClick={(e) => e.stopPropagation()}>
        {items.map((item, i) => (
          <div
            key={i}
            style={{
              ...menuStyles.item,
              color: item.danger ? "#f38ba8" : "#cdd6f4",
            }}
            onClick={() => { item.action(); onClose(); }}
          >
            {item.label}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Tree Node ─────────────────────────────────────────────────────

interface TreeNodeProps {
  node: EntityNode;
  depth: number;
  selectedId: number | null;
  onSelect: (entityId: number) => void;
  onContextMenu: (e: React.MouseEvent, entityId: number) => void;
  renamingId: number | null;
  onRename: (entityId: number, name: string) => void;
  onStartRename: (entityId: number) => void;
  onToggleVisible: (entityId: number, visible: boolean) => void;
  onToggleSelectable: (entityId: number, selectable: boolean) => void;
}

function TreeNode({
  node, depth, selectedId, onSelect, onContextMenu, renamingId, onRename, onStartRename,
  onToggleVisible, onToggleSelectable,
}: TreeNodeProps) {
  const [expanded, setExpanded] = useLocalState(true);
  const [hovered, setHovered] = useLocalState(false);
  const isSelected = node.id === selectedId;
  const hasChildren = node.children.length > 0;
  const isRenaming = renamingId === node.id;

  const showVisIcon = hovered || !node.visible;
  const showLockIcon = hovered || !node.selectable;

  return (
    <div>
      <div
        style={{
          ...styles.node,
          paddingLeft: 8 + depth * 16,
          background: isSelected ? "rgba(137,180,250,0.15)" : "transparent",
          borderLeft: isSelected ? "2px solid #89b4fa" : "2px solid transparent",
        }}
        onClick={() => onSelect(node.id)}
        onContextMenu={(e) => { e.stopPropagation(); onContextMenu(e, node.id); }}
        onDoubleClick={() => onStartRename(node.id)}
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => setHovered(false)}
      >
        {hasChildren ? (
          <span
            style={styles.arrow}
            onClick={(e) => { e.stopPropagation(); setExpanded(!expanded); }}
          >
            {expanded ? <IconTriangleDown size={10} /> : <IconTriangleRight size={10} />}
          </span>
        ) : (
          <span style={styles.arrowPlaceholder} />
        )}
        {isRenaming ? (
          <InlineRename name={node.name} onCommit={(name) => onRename(node.id, name)} />
        ) : (
          <span style={{ flex: 1, opacity: node.visible ? 1 : 0.4 }}>{node.name}</span>
        )}
        <span style={styles.iconGroup}>
          {showVisIcon && (
            <span
              style={{ ...styles.toggleIcon, opacity: node.visible ? 0.4 : 0.8 }}
              title={node.visible ? "Hide" : "Show"}
              onClick={(e) => { e.stopPropagation(); onToggleVisible(node.id, !node.visible); }}
            >
              {node.visible ? <IconShadingRendered size={12} /> : <IconEyeSlash size={12} />}
            </span>
          )}
          {showLockIcon && (
            <span
              style={{ ...styles.toggleIcon, opacity: node.selectable ? 0.4 : 0.8 }}
              title={node.selectable ? "Lock" : "Unlock"}
              onClick={(e) => { e.stopPropagation(); onToggleSelectable(node.id, !node.selectable); }}
            >
              {node.selectable ? <IconLockOpen size={12} /> : <IconLockClosed size={12} />}
            </span>
          )}
        </span>
      </div>
      {expanded &&
        hasChildren &&
        node.children.map((child) => (
          <TreeNode
            key={child.id}
            node={child}
            depth={depth + 1}
            selectedId={selectedId}
            onSelect={onSelect}
            onContextMenu={onContextMenu}
            renamingId={renamingId}
            onRename={onRename}
            onStartRename={onStartRename}
            onToggleVisible={onToggleVisible}
            onToggleSelectable={onToggleSelectable}
          />
        ))}
    </div>
  );
}

// ── Inline rename input ───────────────────────────────────────────

function InlineRename({ name, onCommit }: { name: string; onCommit: (name: string) => void }) {
  const [value, setValue] = useLocalState(name);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.select();
  }, []);

  return (
    <input
      ref={inputRef}
      type="text"
      value={value}
      onChange={(e) => setValue(e.target.value)}
      onBlur={() => onCommit(value)}
      onKeyDown={(e) => {
        if (e.key === "Enter") onCommit(value);
        if (e.key === "Escape") onCommit(name); // revert
      }}
      onClick={(e) => e.stopPropagation()}
      style={styles.renameInput}
    />
  );
}

// ── Styles ────────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", height: "100%", outline: "none" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  title: {},
  searchBar: {
    display: "flex",
    alignItems: "center",
    padding: "6px 8px",
    borderBottom: "1px solid #313244",
  },
  searchInput: {
    flex: 1,
    background: "#1e1e2e",
    border: "1px solid #313244",
    borderRadius: 4,
    color: "#cdd6f4",
    padding: "5px 8px",
    fontSize: 11,
    outline: "none",
  },
  clearSearch: {
    marginLeft: 4,
    cursor: "pointer",
    color: "#6c7086",
    fontSize: 12,
    padding: "2px 4px",
  },
  tree: { flex: 1, overflow: "auto", padding: "4px 0" },
  empty: { padding: 24, textAlign: "center", color: "#585b70", fontSize: 12 },
  node: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "5px 8px",
    cursor: "pointer",
    fontSize: 12,
    borderRadius: 0,
    userSelect: "none",
    transition: "background 0.1s",
    color: "#cdd6f4",
  },
  arrow: {
    width: 14,
    textAlign: "center",
    cursor: "pointer",
    fontSize: 10,
    color: "#6c7086",
  },
  arrowPlaceholder: { width: 14 },
  iconGroup: {
    display: "flex",
    alignItems: "center",
    gap: 2,
    marginLeft: "auto",
    flexShrink: 0,
  },
  toggleIcon: {
    cursor: "pointer",
    fontSize: 12,
    padding: "0 2px",
    lineHeight: 1,
    userSelect: "none" as const,
  },
  renameInput: {
    background: "#313244",
    border: "1px solid #89b4fa",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "1px 4px",
    fontSize: 13,
    outline: "none",
    flex: 1,
  },
};

const menuStyles: Record<string, React.CSSProperties> = {
  overlay: {
    position: "fixed",
    inset: 0,
    zIndex: 1000,
  },
  menu: {
    position: "fixed",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 6,
    padding: "4px 0",
    minWidth: 160,
    boxShadow: "0 4px 12px rgba(0,0,0,0.4)",
    zIndex: 1001,
  },
  item: {
    padding: "6px 12px",
    fontSize: 12,
    cursor: "pointer",
    transition: "background 0.1s",
  },
};
