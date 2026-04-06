import React, { useEffect, useCallback, useMemo } from "react";
import { useLocalState } from "../store/local-state";
import { useSyncedState } from "../store/synced-state";
import {
  IconModel, IconTexture, IconShader, IconScene,
  IconScript, IconAudio, IconMaterial, IconFile, IconRefresh,
} from "../components/Icons";
import { useConnectionStore } from "../store";

// ── Types ────────────────────────────────────────────────────────

interface FlatAsset {
  name: string;
  path: string;
  assetType: string;
  size: number;
  /** directory relative to project root, e.g. "Content/environments" */
  directory: string;
}

type ViewMode = "list" | "grid";

const ASSET_TYPE_ICONS: Record<string, React.ComponentType<{ size?: number; color?: string }>> = {
  model: IconModel,
  texture: IconTexture,
  shader: IconShader,
  scene: IconScene,
  script: IconScript,
  audio: IconAudio,
  material: IconMaterial,
  unknown: IconFile,
};

const TYPE_COLORS: Record<string, string> = {
  model: "#fab387",
  texture: "#a6e3a1",
  shader: "#cba6f7",
  scene: "#89b4fa",
  script: "#f9e2af",
  audio: "#f38ba8",
  material: "#94e2d5",
  unknown: "#6c7086",
};

const ALL_ASSET_TYPES = ["model", "texture", "shader", "scene", "script", "audio", "material", "unknown"] as const;

// ── AssetManager ─────────────────────────────────────────────────

export function AssetManager() {
  const connected = useConnectionStore((s) => s.connected);
  const [allAssets, setAllAssets] = useLocalState<FlatAsset[]>([]);
  const [loading, setLoading] = useLocalState(false);
  const [searchQuery, setSearchQuery] = useLocalState("");
  const [viewMode, setViewMode] = useSyncedState<ViewMode>("asset-manager", "viewMode", "list");
  const [activeTypeFilters, setActiveTypeFilters] = useSyncedState<string[]>("asset-manager", "typeFilters", []);
  const [sortBy, setSortBy] = useSyncedState<"name" | "type" | "size">("asset-manager", "sortBy", "name");

  // Recursively scan all directories and build flat asset index
  const scanAll = useCallback(async () => {
    if (!connected) return;
    setLoading(true);
    const found: FlatAsset[] = [];

    const scanDir = async (dirPath: string) => {
      try {
        const rpcMethod = dirPath === "." ? "assets.listProjectRoot" : "assets.list";
        const result = await window.guavaEngine.call(rpcMethod as "assets.list", { path: dirPath });
        for (const entry of result.entries ?? []) {
          if (entry.isDirectory) {
            await scanDir(entry.path);
          } else {
            found.push({
              name: entry.name,
              path: entry.path,
              assetType: entry.assetType ?? "unknown",
              size: entry.size ?? 0,
              directory: entry.path.includes("/")
                ? entry.path.substring(0, entry.path.lastIndexOf("/"))
                : ".",
            });
          }
        }
      } catch {
        /* ignore scan errors */
      }
    };

    await scanDir(".");
    setAllAssets(found);
    setLoading(false);
  }, [connected]);

  useEffect(() => {
    scanAll();
  }, [scanAll]);

  // Toggle type filter
  const toggleTypeFilter = useCallback(
    (type: string) => {
      setActiveTypeFilters((prev) => {
        const arr = Array.isArray(prev) ? prev : [];
        return arr.includes(type) ? arr.filter((t) => t !== type) : [...arr, type];
      });
    },
    [setActiveTypeFilters],
  );

  // Filter and sort
  const filteredAssets = useMemo(() => {
    let result = allAssets;

    // Type filter
    const filters = Array.isArray(activeTypeFilters) ? activeTypeFilters : [];
    if (filters.length > 0) {
      result = result.filter((a) => filters.includes(a.assetType));
    }

    // Search
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      result = result.filter(
        (a) => a.name.toLowerCase().includes(q) || a.path.toLowerCase().includes(q),
      );
    }

    // Sort
    result = [...result].sort((a, b) => {
      if (sortBy === "name") return a.name.localeCompare(b.name);
      if (sortBy === "type") return a.assetType.localeCompare(b.assetType) || a.name.localeCompare(b.name);
      if (sortBy === "size") return b.size - a.size;
      return 0;
    });

    return result;
  }, [allAssets, activeTypeFilters, searchQuery, sortBy]);

  // Type stats
  const typeStats = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const a of allAssets) {
      counts[a.assetType] = (counts[a.assetType] ?? 0) + 1;
    }
    return counts;
  }, [allAssets]);

  const formatSize = (bytes: number) => {
    if (bytes === 0) return "—";
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  if (!connected) {
    return (
      <div style={styles.container}>
        <div style={styles.headerBar}>
          <span style={styles.title}>Asset Manager</span>
        </div>
        <div style={styles.empty}>Not connected</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      {/* Header */}
      <div style={styles.headerBar}>
        <span style={styles.title}>Asset Manager</span>
        <span style={styles.assetCount}>
          {filteredAssets.length}{allAssets.length !== filteredAssets.length && ` / ${allAssets.length}`}
        </span>
        <button
          style={styles.iconBtn}
          onClick={async () => {
            const res = await window.guavaEngine.fsImportFiles("Content");
            if (res.ok && (res.files?.length ?? 0) > 0) {
              scanAll();
            }
          }}
          title="Import files"
        >
          +
        </button>
        <button style={styles.iconBtn} onClick={scanAll} title="Refresh">
          <IconRefresh size={14} />
        </button>
      </div>

      {/* Search + view mode */}
      <div style={styles.searchRow}>
        <input
          style={styles.searchInput}
          placeholder="Search assets…"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />
        <button
          style={{ ...styles.viewBtn, ...(viewMode === "list" ? styles.viewBtnActive : {}) }}
          onClick={() => setViewMode("list")}
          title="List view"
        >
          ☰
        </button>
        <button
          style={{ ...styles.viewBtn, ...(viewMode === "grid" ? styles.viewBtnActive : {}) }}
          onClick={() => setViewMode("grid")}
          title="Grid view"
        >
          ⊞
        </button>
      </div>

      {/* Type filter chips */}
      <div style={styles.filterRow}>
        {ALL_ASSET_TYPES.map((type) => {
          const count = typeStats[type] ?? 0;
          if (count === 0) return null;
          const filters = Array.isArray(activeTypeFilters) ? activeTypeFilters : [];
          const active = filters.includes(type);
          return (
            <button
              key={type}
              style={{
                ...styles.chip,
                borderColor: active ? TYPE_COLORS[type] : "#45475a",
                color: active ? TYPE_COLORS[type] : "#6c7086",
                background: active ? `${TYPE_COLORS[type]}15` : "transparent",
              }}
              onClick={() => toggleTypeFilter(type)}
            >
              {type} ({count})
            </button>
          );
        })}
        {/* Sort */}
        <select
          value={sortBy}
          onChange={(e) => setSortBy(e.target.value as "name" | "type" | "size")}
          style={styles.sortSelect}
        >
          <option value="name">Name</option>
          <option value="type">Type</option>
          <option value="size">Size</option>
        </select>
      </div>

      {/* Asset list */}
      {loading ? (
        <div style={styles.empty}>Scanning project…</div>
      ) : filteredAssets.length === 0 ? (
        <div style={styles.empty}>{searchQuery || (Array.isArray(activeTypeFilters) && activeTypeFilters.length > 0) ? "No matching assets" : "No assets found"}</div>
      ) : viewMode === "list" ? (
        <div style={styles.listContainer}>
          {filteredAssets.map((asset) => (
            <AssetListItem key={asset.path} asset={asset} formatSize={formatSize} />
          ))}
        </div>
      ) : (
        <div style={styles.gridContainer}>
          {filteredAssets.map((asset) => (
            <AssetGridItem key={asset.path} asset={asset} formatSize={formatSize} />
          ))}
        </div>
      )}
    </div>
  );
}

// ── List item ────────────────────────────────────────────────────

function AssetListItem({ asset, formatSize }: { asset: FlatAsset; formatSize: (n: number) => string }) {
  const Icon = ASSET_TYPE_ICONS[asset.assetType] ?? IconFile;
  return (
    <div
      style={styles.listItem}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.setData("application/x-guava-asset-path", asset.path);
        e.dataTransfer.setData("application/x-guava-asset-type", asset.assetType);
        e.dataTransfer.effectAllowed = "link";
      }}
      onMouseEnter={(e) => (e.currentTarget.style.background = "#313244")}
      onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
    >
      <span style={{ color: TYPE_COLORS[asset.assetType] ?? "#6c7086" }}>
        <Icon size={14} />
      </span>
      <span style={styles.listName}>{asset.name}</span>
      <span style={styles.listDir}>{asset.directory}</span>
      <span style={styles.listSize}>{formatSize(asset.size)}</span>
    </div>
  );
}

// ── Grid item ────────────────────────────────────────────────────

function AssetGridItem({ asset, formatSize }: { asset: FlatAsset; formatSize: (n: number) => string }) {
  const Icon = ASSET_TYPE_ICONS[asset.assetType] ?? IconFile;
  return (
    <div
      style={styles.gridItem}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.setData("application/x-guava-asset-path", asset.path);
        e.dataTransfer.setData("application/x-guava-asset-type", asset.assetType);
        e.dataTransfer.effectAllowed = "link";
      }}
      onMouseEnter={(e) => (e.currentTarget.style.background = "#313244")}
      onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
      title={`${asset.path}\n${formatSize(asset.size)}`}
    >
      <div style={{ ...styles.gridIcon, color: TYPE_COLORS[asset.assetType] ?? "#6c7086" }}>
        <Icon size={28} />
      </div>
      <div style={styles.gridName}>{asset.name}</div>
      <div style={styles.gridType}>{asset.assetType}</div>
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    color: "#cdd6f4",
    fontSize: 13,
  },
  headerBar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "8px 12px 4px",
  },
  title: {
    fontSize: 14,
    fontWeight: 600,
    color: "#89b4fa",
  },
  assetCount: {
    fontSize: 11,
    color: "#6c7086",
    flex: 1,
  },
  iconBtn: {
    background: "transparent",
    border: "none",
    color: "#a6adc8",
    cursor: "pointer",
    padding: "2px 6px",
    borderRadius: 4,
  },
  searchRow: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "4px 12px",
  },
  searchInput: {
    flex: 1,
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#cdd6f4",
    padding: "4px 8px",
    fontSize: 12,
    outline: "none",
    boxSizing: "border-box" as const,
  },
  viewBtn: {
    background: "transparent",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#6c7086",
    cursor: "pointer",
    padding: "2px 6px",
    fontSize: 12,
  },
  viewBtnActive: {
    color: "#89b4fa",
    borderColor: "#89b4fa",
  },
  filterRow: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "2px 12px 6px",
    flexWrap: "wrap" as const,
  },
  chip: {
    padding: "1px 8px",
    borderRadius: 10,
    border: "1px solid #45475a",
    background: "transparent",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 10,
    whiteSpace: "nowrap" as const,
  },
  sortSelect: {
    marginLeft: "auto",
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#a6adc8",
    fontSize: 10,
    padding: "1px 4px",
  },
  empty: {
    opacity: 0.4,
    textAlign: "center",
    padding: 24,
  },
  // List view
  listContainer: {
    flex: 1,
    overflow: "auto",
    paddingBottom: 8,
  },
  listItem: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "3px 12px",
    cursor: "grab",
    transition: "background 0.1s",
  },
  listName: {
    flex: 1,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
    fontSize: 12,
  },
  listDir: {
    fontSize: 10,
    color: "#6c7086",
    maxWidth: 160,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  listSize: {
    fontSize: 10,
    color: "#6c7086",
    width: 60,
    textAlign: "right" as const,
  },
  // Grid view
  gridContainer: {
    flex: 1,
    overflow: "auto",
    display: "flex",
    flexWrap: "wrap" as const,
    gap: 4,
    padding: "4px 12px",
    alignContent: "flex-start",
  },
  gridItem: {
    width: 80,
    padding: "8px 4px 4px",
    borderRadius: 4,
    cursor: "grab",
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    gap: 2,
    transition: "background 0.1s",
  },
  gridIcon: {
    width: 40,
    height: 40,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  gridName: {
    fontSize: 10,
    textAlign: "center" as const,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
    width: "100%",
  },
  gridType: {
    fontSize: 9,
    color: "#6c7086",
    textTransform: "uppercase" as const,
  },
};
