import React, { useEffect, useCallback, useRef } from "react";
import { useLocalState } from "../store/local-state";
import type { AssetEntry } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";
import {
  IconFolder, IconModel, IconTexture, IconShader, IconScene,
  IconScript, IconAudio, IconMaterial, IconFile, IconRefresh,
} from "../components/Icons";
import { useConnectionStore } from "../store";
import { useEditorStore } from "../store/editor";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";
import { engine } from "../engine-client";
import { fsMkdir, fsCreateFile, fsDelete, fsRename, fsImportFiles, fsImportPaths } from "../citron-api";

// ── Types ────────────────────────────────────────────────────────

interface TreeNode {
  name: string;
  path: string;
  isDirectory: boolean;
  assetType?: string;
  size?: number;
  children?: TreeNode[];
  loaded?: boolean;
}

const ASSET_ICONS: Record<string, React.ComponentType<{ size?: number; color?: string }>> = {
  folder: IconFolder,
  model: IconModel,
  texture: IconTexture,
  shader: IconShader,
  scene: IconScene,
  script: IconScript,
  audio: IconAudio,
  material: IconMaterial,
  unknown: IconFile,
};

export function AssetBrowser() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [roots, setRoots] = useLocalState<TreeNode[]>([]);
  const [expanded, setExpanded] = useSyncedState<Set<string>>("asset-browser", "expandedPaths", new Set());
  const [selected, setSelected] = useLocalState<string | null>(null);
  const [contextMenu, setContextMenu] = useLocalState<{ x: number; y: number; node: TreeNode } | null>(null);
  const [renaming, setRenaming] = useLocalState<string | null>(null);
  const [renameValue, setRenameValue] = useLocalState("");
  const [fileDragOver, setFileDragOver] = useLocalState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  // Fetch directory contents
  const fetchDir = useCallback(
    async (dirPath: string): Promise<TreeNode[]> => {
      if (!connected) return [];
      try {
        const rpcMethod = dirPath === "." ? "assets.listProjectRoot" : "assets.list";
        const result = await engine.call(rpcMethod as "assets.list", { path: dirPath });
        return (result.entries ?? []).map((e: AssetEntry) => ({
          name: e.name,
          path: e.path,
          isDirectory: e.isDirectory,
          assetType: e.assetType,
          size: e.size,
          children: e.isDirectory ? [] : undefined,
          loaded: !e.isDirectory,
        }));
      } catch {
        return [];
      }
    },
    [connected],
  );

  // Load root
  useEffect(() => {
    fetchDir(".").then(setRoots);
  }, [connected, fetchDir]);

  // Toggle expand/collapse
  const toggleExpand = useCallback(
    async (node: TreeNode) => {
      if (!node.isDirectory) return;

      setExpanded((prev) => {
        const next = new Set(prev);
        if (next.has(node.path)) {
          next.delete(node.path);
        } else {
          next.add(node.path);
        }
        return next;
      });

      // Load children if not yet loaded
      if (!node.loaded) {
        const children = await fetchDir(node.path);
        setRoots((prev) => updateNodeChildren(prev, node.path, children));
      }
    },
    [fetchDir],
  );

  // Refresh a specific directory
  const refreshDir = useCallback(
    async (dirPath: string) => {
      if (dirPath === ".") {
        const newRoots = await fetchDir(".");
        // Preserve expanded subtrees
        setRoots((prev) => mergeChildren(prev, newRoots));
      } else {
        const children = await fetchDir(dirPath);
        setRoots((prev) => updateNodeChildren(prev, dirPath, children));
      }
    },
    [fetchDir],
  );

  // Refresh all
  const refreshAll = useCallback(async () => {
    const newRoots = await fetchDir(".");
    setRoots(newRoots);
  }, [fetchDir]);

  // Select a node
  const handleSelect = useCallback((node: TreeNode) => {
    setSelected(node.path);
  }, []);

  // Double-click: open script files in ScriptViewer
  const handleDoubleClick = useCallback((node: TreeNode) => {
    if (!node.isDirectory && node.assetType === "script") {
      useEditorStore.getState().openScript(node.path);
    }
  }, []);

  // Right-click context menu
  const handleContextMenu = useCallback(
    (e: React.MouseEvent, node: TreeNode) => {
      e.preventDefault();
      setContextMenu({ x: e.clientX, y: e.clientY, node });
    },
    [],
  );

  // Close context menu on click outside
  useEffect(() => {
    const handler = () => setContextMenu(null);
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, []);

  // Context menu actions
  const handleNewFolder = useCallback(
    async (parentPath: string) => {
      setContextMenu(null);
      const parent = parentPath === "." ? undefined : findNode(roots, parentPath);
      const siblings = parentPath === "." ? roots : parent?.children ?? [];
      const name = uniqueName(siblings, "New Folder", "");
      const newPath = parentPath === "." ? name : `${parentPath}/${name}`;
      const res = await fsMkdir(newPath);
      if (res.ok) {
        await refreshDir(parentPath);
        setExpanded((prev) => new Set(prev).add(parentPath));
        setRenaming(newPath);
        setRenameValue(name);
      }
    },
    [refreshDir, roots],
  );

  const handleNewScript = useCallback(
    async (parentPath: string) => {
      setContextMenu(null);
      const parent = parentPath === "." ? undefined : findNode(roots, parentPath);
      const siblings = parentPath === "." ? roots : parent?.children ?? [];
      const name = uniqueName(siblings, "new_script", ".zig");
      const newPath = parentPath === "." ? name : `${parentPath}/${name}`;
      const template = "const guava = @import(\"guava\");\n\nexport fn guava_on_init() void {}\n\nexport fn guava_on_update(_dt: f32) void {}\n";
      const res = await fsCreateFile(newPath, template);
      if (res.ok) {
        await refreshDir(parentPath);
        setExpanded((prev) => new Set(prev).add(parentPath));
        setRenaming(newPath);
        setRenameValue(name);
      }
    },
    [refreshDir, roots],
  );

  const handleDelete = useCallback(
    async (node: TreeNode) => {
      setContextMenu(null);
      const res = await fsDelete(node.path);
      if (res.ok) {
        const parent = node.path.includes("/") ? node.path.substring(0, node.path.lastIndexOf("/")) : ".";
        await refreshDir(parent);
      }
    },
    [refreshDir],
  );

  const handleRenameStart = useCallback(
    (node: TreeNode) => {
      setContextMenu(null);
      setRenaming(node.path);
      setRenameValue(node.name);
    },
    [],
  );

  const commitRename = useCallback(
    async (oldPath: string) => {
      if (!renameValue.trim()) {
        setRenaming(null);
        return;
      }
      const parent = oldPath.includes("/") ? oldPath.substring(0, oldPath.lastIndexOf("/")) : ".";
      const newPath = parent === "." ? renameValue.trim() : `${parent}/${renameValue.trim()}`;
      if (newPath !== oldPath) {
        const res = await fsRename(oldPath, newPath);
        if (res.ok) {
          await refreshDir(parent);
        }
      }
      setRenaming(null);
    },
    [renameValue, refreshDir],
  );

  const handleImport = useCallback(
    async (targetDir: string) => {
      setContextMenu(null);
      const res = await fsImportFiles(targetDir);
      if (res.ok && (res.files?.length ?? 0) > 0) {
        await refreshDir(targetDir);
      }
    },
    [refreshDir],
  );

  const expandedSet = expanded instanceof Set ? expanded : new Set<string>();

  return (
    <div style={styles.container} ref={containerRef}>
      {/* Header */}
      <div style={styles.header}>
        <span style={styles.title}>{t.assets.title}</span>
        <button style={styles.refreshBtn} onClick={refreshAll} title={t.assets.refreshTooltip}>
          <IconRefresh size={14} />
        </button>
      </div>

      {/* Tree */}
      <div
        style={{
          ...styles.tree,
          ...(fileDragOver ? { outline: "2px dashed #89b4fa", outlineOffset: -2, background: "rgba(137,180,250,0.04)" } : {}),
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          setContextMenu({
            x: e.clientX,
            y: e.clientY,
            node: { name: "Project", path: ".", isDirectory: true, loaded: true },
          });
        }}
        onDragOver={(e) => {
          if (e.dataTransfer.types.includes("Files")) {
            e.preventDefault();
            e.dataTransfer.dropEffect = "copy";
            setFileDragOver(true);
          }
        }}
        onDragLeave={() => setFileDragOver(false)}
        onDrop={async (e) => {
          if (!e.dataTransfer.types.includes("Files")) return;
          e.preventDefault();
          setFileDragOver(false);
          const paths: string[] = [];
          for (const f of Array.from(e.dataTransfer.files)) {
            if ((f as unknown as { path?: string }).path) {
              paths.push((f as unknown as { path: string }).path);
            }
          }
          if (paths.length > 0) {
            const targetDir = selected
              ? (roots.some((r) => r.path === selected && r.isDirectory) ? selected : "Content")
              : "Content";
            const res = await fsImportPaths(targetDir, paths);
            if (res.ok && (res.files?.length ?? 0) > 0) {
              await refreshDir(targetDir);
            }
          }
        }}
      >
        {roots.length === 0 ? (
          <div style={styles.empty}>{connected ? t.assets.emptyDirectory : "Not connected"}</div>
        ) : (
          roots.map((node) => (
            <TreeItem
              key={node.path}
              node={node}
              depth={0}
              expanded={expandedSet}
              selected={selected}
              renaming={renaming}
              renameValue={renameValue}
              onToggle={toggleExpand}
              onSelect={handleSelect}
              onDoubleClick={handleDoubleClick}
              onContextMenu={handleContextMenu}
              onRenameChange={setRenameValue}
              onRenameCommit={commitRename}
            />
          ))
        )}
      </div>

      {/* Context menu */}
      {contextMenu && (
        <div
          style={{
            ...styles.menu,
            left: contextMenu.x,
            top: contextMenu.y,
          }}
          onClick={(e) => e.stopPropagation()}
        >
          {contextMenu.node.isDirectory && (
            <>
              <div style={styles.menuItem} onClick={() => handleNewFolder(contextMenu.node.path)}>
                New Folder
              </div>
              <div style={styles.menuItem} onClick={() => handleNewScript(contextMenu.node.path)}>
                New Script
              </div>
              <div style={styles.menuItem} onClick={() => handleImport(contextMenu.node.path)}>
                Import Files…
              </div>
              <div style={styles.menuSeparator} />
            </>
          )}
          {contextMenu.node.path !== "." && (
            <>
              <div style={styles.menuItem} onClick={() => handleRenameStart(contextMenu.node)}>
                Rename
              </div>
              <div
                style={{ ...styles.menuItem, color: "#f38ba8" }}
                onClick={() => handleDelete(contextMenu.node)}
              >
                Delete
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ── TreeItem ─────────────────────────────────────────────────────

function TreeItem({
  node,
  depth,
  expanded,
  selected,
  renaming,
  renameValue,
  onToggle,
  onSelect,
  onDoubleClick,
  onContextMenu,
  onRenameChange,
  onRenameCommit,
}: {
  node: TreeNode;
  depth: number;
  expanded: Set<string>;
  selected: string | null;
  renaming: string | null;
  renameValue: string;
  onToggle: (node: TreeNode) => void;
  onSelect: (node: TreeNode) => void;
  onDoubleClick: (node: TreeNode) => void;
  onContextMenu: (e: React.MouseEvent, node: TreeNode) => void;
  onRenameChange: (v: string) => void;
  onRenameCommit: (oldPath: string) => void;
}) {
  const isExpanded = expanded.has(node.path);
  const isSelected = selected === node.path;
  const isRenaming = renaming === node.path;
  const Icon = node.isDirectory
    ? IconFolder
    : ASSET_ICONS[node.assetType ?? "unknown"] ?? IconFile;

  return (
    <>
      <div
        style={{
          ...styles.treeRow,
          paddingLeft: 8 + depth * 16,
          ...(isSelected ? styles.treeRowSelected : {}),
        }}
        onClick={() => {
          onSelect(node);
          if (node.isDirectory) onToggle(node);
        }}
        onDoubleClick={() => onDoubleClick(node)}
        onContextMenu={(e) => onContextMenu(e, node)}
        draggable={!node.isDirectory}
        onDragStart={(e) => {
          if (node.isDirectory) return;
          e.dataTransfer.setData("application/x-guava-asset-path", node.path);
          e.dataTransfer.setData("application/x-guava-asset-type", node.assetType ?? "unknown");
          e.dataTransfer.effectAllowed = "link";
        }}
        onMouseEnter={(e) => {
          if (!isSelected) e.currentTarget.style.background = "#313244";
        }}
        onMouseLeave={(e) => {
          if (!isSelected) e.currentTarget.style.background = "transparent";
        }}
      >
        {/* Arrow */}
        <span style={styles.arrow}>
          {node.isDirectory ? (
            isExpanded ? <IconTriangleDown size={10} /> : <IconTriangleRight size={10} />
          ) : (
            <span style={{ width: 10, display: "inline-block" }} />
          )}
        </span>
        {/* Icon */}
        <span style={styles.icon}><Icon size={14} /></span>
        {/* Name or rename input */}
        {isRenaming ? (
          <input
            autoFocus
            value={renameValue}
            onChange={(e) => onRenameChange(e.target.value)}
            onBlur={() => onRenameCommit(node.path)}
            onKeyDown={(e) => {
              if (e.key === "Enter") onRenameCommit(node.path);
              if (e.key === "Escape") onRenameCommit(node.path);
            }}
            onClick={(e) => e.stopPropagation()}
            style={styles.renameInput}
          />
        ) : (
          <span style={styles.treeName}>{node.name}</span>
        )}
      </div>
      {/* Children */}
      {node.isDirectory && isExpanded && node.children?.map((child) => (
        <TreeItem
          key={child.path}
          node={child}
          depth={depth + 1}
          expanded={expanded}
          selected={selected}
          renaming={renaming}
          renameValue={renameValue}
          onToggle={onToggle}
          onSelect={onSelect}
          onDoubleClick={onDoubleClick}
          onContextMenu={onContextMenu}
          onRenameChange={onRenameChange}
          onRenameCommit={onRenameCommit}
        />
      ))}
    </>
  );
}

// ── Helpers ──────────────────────────────────────────────────────

function updateNodeChildren(
  nodes: TreeNode[],
  targetPath: string,
  children: TreeNode[],
): TreeNode[] {
  return nodes.map((node) => {
    if (node.path === targetPath) {
      return { ...node, children, loaded: true };
    }
    if (node.children) {
      return { ...node, children: updateNodeChildren(node.children, targetPath, children) };
    }
    return node;
  });
}

function mergeChildren(
  oldNodes: TreeNode[],
  newNodes: TreeNode[],
): TreeNode[] {
  return newNodes.map((newNode) => {
    const existing = oldNodes.find((o) => o.path === newNode.path);
    if (existing && existing.isDirectory && existing.loaded && existing.children) {
      return { ...newNode, children: existing.children, loaded: true };
    }
    return newNode;
  });
}

/** Find a node by path in the tree. */
function findNode(nodes: TreeNode[], path: string): TreeNode | undefined {
  for (const n of nodes) {
    if (n.path === path) return n;
    if (n.children) {
      const found = findNode(n.children, path);
      if (found) return found;
    }
  }
  return undefined;
}

/** Generate a unique name among siblings, appending _2, _3, … on collision. */
function uniqueName(siblings: TreeNode[], baseName: string, ext: string): string {
  const existingNames = new Set(siblings.map((s) => s.name));
  let candidate = `${baseName}${ext}`;
  let i = 2;
  while (existingNames.has(candidate)) {
    candidate = `${baseName}_${i}${ext}`;
    i++;
  }
  return candidate;
}

// ── Styles ───────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    color: "#cdd6f4",
    fontSize: 13,
    position: "relative",
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "8px 12px 4px",
  },
  title: {
    fontSize: 14,
    fontWeight: 600,
    color: "#89b4fa",
  },
  refreshBtn: {
    background: "transparent",
    border: "none",
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 14,
    padding: "2px 6px",
    borderRadius: 4,
  },
  tree: {
    flex: 1,
    overflow: "auto",
    paddingBottom: 8,
  },
  treeRow: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "2px 8px",
    cursor: "pointer",
    transition: "background 0.1s",
    userSelect: "none",
  },
  treeRowSelected: {
    background: "#45475a",
  },
  arrow: {
    width: 14,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    color: "#6c7086",
    flexShrink: 0,
  },
  icon: {
    width: 18,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
  treeName: {
    flex: 1,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: 12,
  },
  renameInput: {
    flex: 1,
    background: "#313244",
    border: "1px solid #89b4fa",
    borderRadius: 2,
    color: "#cdd6f4",
    padding: "1px 4px",
    fontSize: 12,
    outline: "none",
  },
  empty: {
    padding: 16,
    textAlign: "center",
    opacity: 0.4,
  },
  menu: {
    position: "fixed",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 6,
    padding: "4px 0",
    minWidth: 160,
    zIndex: 9999,
    boxShadow: "0 4px 12px rgba(0,0,0,0.4)",
  },
  menuItem: {
    padding: "6px 12px",
    cursor: "pointer",
    fontSize: 12,
    color: "#cdd6f4",
    transition: "background 0.1s",
  },
  menuSeparator: {
    height: 1,
    background: "#45475a",
    margin: "4px 0",
  },
};
